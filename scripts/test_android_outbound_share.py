#!/usr/bin/env python3
"""Verify production sharing through a disposable local receiving Activity."""
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
    if len(sys.argv) != 3 or not re.fullmatch(r"emulator-\d+", sys.argv[1]):
        raise SystemExit("Usage: test_android_outbound_share.py emulator-5554 fixture.apk")
    device, apk = sys.argv[1:]
    root = Path(__file__).resolve().parents[1]
    command = [str(Path.home() / "Library/Android/sdk/platform-tools/adb"), "-s", device]

    def adb(*args):
        return subprocess.check_output(command + list(args), timeout=30)

    assert adb("shell", "getprop", "ro.kernel.qemu").strip() == b"1"
    assert adb("shell", "getprop", "sys.boot_completed").strip() == b"1"
    width, height = map(int, re.findall(
        r"(\d+)x(\d+)", adb("shell", "wm", "size").decode())[-1])
    # This package is only the disposable test sender/receiver, never Gemsnote.
    subprocess.run(command + ["uninstall", "com.github.gemsnote.sharefixture"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    adb("install", apk)
    work = Path(tempfile.mkdtemp(prefix="gemsnote-outbound-share-"))
    run = uuid.uuid4().hex
    print(f"Evidence: {work}", flush=True)
    (work / "run.txt").write_text(run)
    log_path = work / "flutter.log"
    flutter = os.environ.get("FLUTTER_BIN", str(Path.home() / "opt/flutter/bin/flutter"))
    remote_xml = f"/sdcard/gemsnote-outbound-{run}.xml"

    def nodes(stage):
        adb("shell", "uiautomator", "dump", remote_xml)
        xml = adb("shell", "cat", remote_xml)
        (work / f"{stage}.xml").write_bytes(xml)
        return list(ET.fromstring(xml).iter("node"))

    with log_path.open("w") as log:
        process = subprocess.Popen([
            flutter, "test", "--no-pub", "--no-uninstall",
            "integration_test/android_outbound_share_test.dart", "-d", device,
            f"--dart-define=OUTBOUND_SHARE_RUN={run}",
        ], cwd=root, stdout=log, stderr=subprocess.STDOUT)
        try:
            def stage(name):
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    if f"OUTBOUND_SHARE_STAGE:{name}" in log_path.read_text():
                        return
                    if process.poll() is not None:
                        raise RuntimeError(f"Flutter exited before {name}: {work}")
                    time.sleep(0.3)
                raise TimeoutError(f"Missing {name}: {work}")

            for kind in ["md", "html", "binary", "empty"]:
                stage(kind)
                deadline = time.monotonic() + 30
                expanded = False
                while True:
                    target = next((n for n in nodes(kind)
                                   if n.get("text") == "Gemsnote test receiver"), None)
                    if target is not None:
                        xy = list(map(int, re.findall(r"\d+", target.get("bounds"))))
                        adb("shell", "input", "tap", str((xy[0] + xy[2]) // 2),
                            str((xy[1] + xy[3]) // 2))
                        break
                    if not expanded:
                        adb("shell", "input", "swipe", str(width // 2),
                            str(height * 85 // 100), str(width // 2),
                            str(height * 25 // 100), "400")
                        expanded = True
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"Receiver missing for {kind}: {work}")
            stage("cancel")
            assert any(n.get("text") == "Sharing text" for n in nodes("cancel"))
            adb("shell", "input", "keyevent", "KEYCODE_BACK")
            stage("complete")
            assert process.wait(timeout=45) == 0, f"Flutter failed: {work}"
            raw = adb("exec-out", "run-as", "com.github.gemsnote.sharefixture",
                      "cat", "files/received.jsonl")
            (work / "received.jsonl").write_bytes(raw)
            records = [json.loads(line) for line in raw.splitlines()]
            assert len(records) == 4, "Cancel delivered or a share was lost/duplicated"
            assert all("error" not in item for item in records), records
            assert all(item["action"] == "android.intent.action.SEND" for item in records)
            for kind, body, item in zip(
                ["md", "html"], ["# 原文 📝\n\n**不截断**", "<p>原文 &amp; emoji 📝</p>"],
                records[:2],
            ):
                title = f"share-{run}-{kind}"
                assert item["subject"] == title
                assert item["text"] == title + "\n\n" + body
                assert item["type"] == "text/plain"
                assert not item["hasStream"]
            for item, name, data in [
                (records[2], f"share-{run}-附件_.bin", bytes([0, 1, 127, 128, 255])),
                (records[3], f"share-{run}-empty.bin", b""),
            ]:
                assert item["hasStream"] and item["readGrant"]
                assert item["scheme"] == "content"
                assert item["name"] == name
                assert item["type"] == "application/octet-stream"
                assert base64.b64decode(item["bytes"]) == data
                assert not item.get("text") and not item.get("subject")
            adb("uninstall", "com.github.gemsnote.sharefixture")
            adb("shell", "rm", remote_xml)
            print("PASS: exact Markdown/HTML text, binary/empty originals, URI grants and cancel.")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=15)
    print("Restore the normal lib/main.dart APK after this integration test.")


if __name__ == "__main__":
    main()
