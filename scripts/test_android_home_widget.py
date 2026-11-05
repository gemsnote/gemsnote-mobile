#!/usr/bin/env python3
"""Exercise an already-added widget on a disposable, signed-out Android emulator.

Runs the real Flutter/native channel and checks the launcher's RemoteViews before
each tap. Does not log in, access a server, or clear app data. The Flutter device
runner installs a test entry point; rebuild/reinstall the normal app afterwards.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET


def main():
    if (
        len(sys.argv) not in (2, 3)
        or not sys.argv[1].startswith("emulator-")
        or (len(sys.argv) == 3 and sys.argv[2] != "--workspace")
    ):
        raise SystemExit("Usage: test_android_home_widget.py emulator-5554 [--workspace]")
    device = sys.argv[1]
    workspace = len(sys.argv) == 3
    root = Path(__file__).resolve().parents[1]
    adb_path = os.environ.get(
        "ADB", str(Path.home() / "Library/Android/sdk/platform-tools/adb")
    )
    flutter = os.environ.get("FLUTTER_BIN", str(Path.home() / "opt/flutter/bin/flutter"))

    def adb(*args):
        return subprocess.check_output(
            [adb_path, "-s", device, *args], timeout=30
        ).decode()

    if adb("shell", "getprop", "ro.kernel.qemu").strip() != "1":
        raise RuntimeError("Only a disposable emulator is supported")
    # Refuse an active widget account before any installation or mutation.
    prefs = ET.fromstring(adb(
        "shell", "run-as", "com.github.gemsnote",
        "cat", "shared_prefs/note_widget.xml"
    ))
    if any(n.get("name") == "account" and n.text for n in prefs):
        raise RuntimeError("Sign out on the disposable emulator first")
    run = uuid.uuid4().hex
    work = Path(tempfile.mkdtemp(prefix="gemsnote-widget-ui-"))
    print(f"Evidence: {work}", flush=True)

    def dump(stage):
        remote = f"/sdcard/gemsnote-widget-{run}.xml"
        adb("shell", "uiautomator", "dump", remote)
        xml = adb("shell", "cat", remote)
        (work / f"{stage}.xml").write_text(xml)
        return list(ET.fromstring(xml).iter("node"))

    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    if not any(
        n.get("resource-id") == "com.github.gemsnote:id/widget_title"
        or (
            n.get("class", "").endswith("AppWidgetHostView")
            and n.get("content-desc") in (
                "Gemsnote recent notes", "珠玑笔记最近笔记"
            )
        )
        for n in dump("preflight")
    ):
        raise RuntimeError("Add a Gemsnote widget on the current home screen first")

    expectations = {
        "private-a": ("widget_empty", None, "widget_title"),
        "list-a": ("widget_row", "Widget fixture A", "widget_row"),
        "disabled-a": ("widget_empty", None, "widget_title"),
        "private-b": ("widget_empty", None, "widget_title"),
        "list-b": ("widget_row", "Widget fixture B", "widget_row"),
        "create-b": ("widget_row", "Widget fixture B", "widget_create"),
        "restored-a": ("widget_row", "Widget fixture A restored", "widget_row"),
        "logout": ("widget_empty", None, "widget_title"),
    }
    if workspace:
        expectations = {
            "workspace-open": ("widget_row", "Widget workspace source", "widget_row"),
            "workspace-defer": ("widget_row", "Widget workspace source", "widget_create"),
            "workspace-saved": ("widget_row", "Widget created locally", "widget_row"),
        }
    target = (
        "android_widget_workspace_test.dart"
        if workspace else "android_home_widget_test.dart"
    )
    seen = []
    command = [
        flutter, "test", f"integration_test/{target}",
        "-d", device, "--no-pub", "--no-uninstall", "--reporter", "expanded",
        f"--dart-define=WIDGET_TEST_RUN={run}",
    ]
    with (work / "flutter.log").open("w") as log:
        process = subprocess.Popen(
            command, cwd=root, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        try:
            for line in process.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
                marker = re.search(r"WIDGET_STAGE:([a-z-]+)", line)
                if not marker:
                    continue
                stage = marker.group(1)
                expected_id, expected_text, click_id = expectations[stage]
                adb("shell", "input", "keyevent", "KEYCODE_HOME")
                deadline = time.monotonic() + 45
                while True:
                    nodes = dump(stage)
                    widgets = {
                        n.get("resource-id").split("/")[-1]: n
                        for n in nodes
                        if n.get("resource-id", "").startswith(
                            "com.github.gemsnote:id/widget_"
                        )
                    }
                    node = widgets.get(expected_id)
                    ready = node is not None and (
                        expected_text is None or node.get("text") == expected_text
                    )
                    rows = [
                        n.get("text") for n in nodes
                        if n.get("resource-id") == "com.github.gemsnote:id/widget_row"
                    ]
                    # No stale/foreign titles may remain alongside the current row.
                    expected_rows = (
                        [] if expected_id == "widget_empty" else [expected_text]
                    )
                    if stage == "workspace-saved":
                        expected_rows.append("Widget workspace source")
                    ready = ready and rows == expected_rows
                    if click_id == "widget_row":
                        target_row = next((
                            n for n in nodes
                            if n.get("resource-id") == "com.github.gemsnote:id/widget_row"
                            and n.get("text") == expected_text
                        ), None)
                        # A collection can have multiple rows with the same resource ID.
                        if target_row is not None:
                            widgets[click_id] = target_row
                            ready = rows == expected_rows
                    if ready and click_id in widgets:
                        break
                    if time.monotonic() >= deadline:
                        raise AssertionError(f"{stage}: unexpected widget: {widgets}")
                    time.sleep(0.3)
                if expected_id == "widget_empty":
                    text = node.get("text", "")
                    if stage == "logout":
                        assert text in ("Open Gemsnote to sign in", "打开珠玑笔记登录"), text
                    else:
                        assert text in (
                            "Note titles are hidden. Enable them in the app’s Home widget settings.",
                            "笔记标题已隐藏，可在应用的桌面小组件设置中开启。",
                        ), text
                bounds = [int(v) for v in re.findall(r"\d+", widgets[click_id].get("bounds"))]
                adb("shell", "input", "tap",
                    str((bounds[0] + bounds[2]) // 2),
                    str((bounds[1] + bounds[3]) // 2))
                seen.append(stage)
            if process.wait() != 0:
                raise RuntimeError(f"Flutter device test failed; see {work}")
            if seen != list(expectations):
                raise AssertionError(f"Missing/out-of-order launcher stages: {seen}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    print(f"PASS: {len(expectations)} launcher stages and device assertions.")
    print("Rebuild/install the ordinary lib/main.dart debug APK before further app tests.")


if __name__ == "__main__":
    main()
