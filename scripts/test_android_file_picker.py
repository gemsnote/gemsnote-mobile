#!/usr/bin/env python3
"""Exercise actual DocumentsUI through production importer/exporter services.

Only an emulator is allowed. Uses unique filenames, keeps evidence on failure,
and never clears app data. Reinstall the normal APK after integration testing.
"""
import base64
import json
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
    if len(sys.argv) != 2 or not re.fullmatch(r"emulator-\d+", sys.argv[1]):
        raise SystemExit("Usage: test_android_file_picker.py emulator-5554")
    device = sys.argv[1]
    root = Path(__file__).resolve().parents[1]
    adb_path = str(Path.home() / "Library/Android/sdk/platform-tools/adb")

    def adb(*args):
        return subprocess.check_output([adb_path, "-s", device, *args], timeout=30)

    assert adb("shell", "getprop", "ro.kernel.qemu").strip() == b"1"
    assert adb("shell", "getprop", "sys.boot_completed").strip() == b"1"
    work = Path(tempfile.mkdtemp(prefix="gemsnote-file-picker-"))
    run = uuid.uuid4().hex
    (work / "run.txt").write_text(run)
    print(f"Evidence: {work}", flush=True)
    invalid = work / f"gemsnote-{run}-invalid.exe"
    invalid.write_bytes(b"unsupported fixture, never execute")
    adb("push", str(invalid), f"/sdcard/Download/{invalid.name}")
    log_path = work / "flutter.log"
    flutter = os.environ.get("FLUTTER_BIN", str(Path.home() / "opt/flutter/bin/flutter"))

    def nodes(stage):
        remote = f"/sdcard/gemsnote-picker-{run}.xml"
        adb("shell", "uiautomator", "dump", remote)
        xml = adb("shell", "cat", remote)
        (work / f"{stage}.xml").write_bytes(xml)
        return list(ET.fromstring(xml).iter("node"))

    def click(predicate, stage):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            node = next((n for n in nodes(stage) if predicate(n)), None)
            if node is not None:
                assert node.get("enabled") == "true", f"Disabled picker item: {stage}"
                bounds = list(map(int, re.findall(r"\d+", node.get("bounds"))))
                adb("shell", "input", "tap", str((bounds[0] + bounds[2]) // 2),
                    str((bounds[1] + bounds[3]) // 2))
                return
        raise RuntimeError(f"Missing picker action {stage}; inspect {work}")

    with log_path.open("w") as log:
        process = subprocess.Popen([
            flutter, "test", "--no-pub", "--no-uninstall",
            "integration_test/android_file_picker_test.dart", "-d", device,
            f"--dart-define=FILE_PICKER_RUN={run}",
        ], cwd=root, stdout=log, stderr=subprocess.STDOUT)
        try:
            def wait_stage(stage):
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    if f"FILE_PICKER_STAGE:{stage}" in log_path.read_text():
                        return
                    if process.poll() is not None:
                        raise RuntimeError(f"Flutter exited at {stage}: {log_path}")
                    time.sleep(0.3)
                raise TimeoutError(f"Timed out at {stage}: {log_path}")

            for kind in ["md", "html", "gemsnote"]:
                wait_stage(f"save:{kind}")
                click(lambda n: n.get("text", "").casefold() == "save",
                      f"save-{kind}")
                wait_stage(f"import:{kind}")
                filename = f"gemsnote-{run}-{kind}.{'gemsnote' if kind == 'gemsnote' else 'rtf' if kind == 'html' else 'md'}"
                click(lambda n: n.get("text") == filename, f"import-{kind}")
            wait_stage("invalid")
            click(lambda n: n.get("text") == invalid.name, "invalid")
            for kind in ["export", "import"]:
                wait_stage(f"cancel:{kind}")
                # Wait until the system picker owns the foreground, not Flutter.
                click(lambda n: n.get("content-desc") == "Show roots",
                      f"cancel-{kind}-roots")
                adb("shell", "input", "keyevent", "KEYCODE_BACK")
                adb("shell", "input", "keyevent", "KEYCODE_BACK")
            wait_stage("complete")
            if process.wait(timeout=45) != 0:
                raise RuntimeError(f"Flutter verification failed: {log_path}")
            markdown = "# 原文 📝\n\n换行与 **格式**\n"
            html = "<p>原文 &amp; emoji 📝</p>\n<table><tr><td>保留</td></tr></table>"
            for kind, expected in [("md", markdown), ("html", html)]:
                actual = adb("exec-out", "cat",
                             f"/sdcard/Download/gemsnote-{run}-{kind}.{'gemsnote' if kind == 'gemsnote' else 'rtf' if kind == 'html' else 'md'}")
                text = actual.decode()
                if kind == 'md':
                    assert text.startswith('---\ntitle: ') and text.endswith(markdown)
                else:
                    assert text.startswith(r'{\rtf1') and r'\u' in text and r'\trowd' in text
            archive = json.loads(adb(
                "exec-out", "cat",
                f"/sdcard/Download/gemsnote-{run}-gemsnote.gemsnote"))
            assert archive["note"]["content"] == markdown
            assert base64.b64decode(archive["resources"][0]["bytes"]) == bytes(
                [0, 1, 127, 128, 255])
            listing = adb("shell", "ls", "/sdcard/Download").decode().splitlines()
            assert not any(name.startswith(f"gemsnote-{run}-cancel") for name in listing)
            # Remove only files created by this run after all assertions pass.
            for kind in ["md", "html", "gemsnote"]:
                adb("shell", "rm", f"/sdcard/Download/gemsnote-{run}-{kind}.{'gemsnote' if kind == 'gemsnote' else 'rtf' if kind == 'html' else 'md'}")
            adb("shell", "rm", f"/sdcard/gemsnote-picker-{run}.xml")
            adb("shell", "rm", f"/sdcard/Download/{invalid.name}")
            print("PASS: exact source/binary round trips; unsupported file rejected; both cancels.")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=15)
    print("Rebuild/install the normal lib/main.dart APK after device testing.")


if __name__ == "__main__":
    main()
