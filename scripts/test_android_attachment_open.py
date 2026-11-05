#!/usr/bin/env python3
"""Verify open_filex VIEW handoff through a disposable local viewer."""
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
        raise SystemExit("Usage: test_android_attachment_open.py emulator-5554 fixture.apk")
    device, apk = sys.argv[1:]
    root = Path(__file__).resolve().parents[1]
    adb_path = str(Path.home() / "Library/Android/sdk/platform-tools/adb")

    def adb(*args):
        return subprocess.check_output([adb_path, "-s", device, *args], timeout=30)

    assert adb("shell", "getprop", "ro.kernel.qemu").strip() == b"1"
    assert adb("shell", "getprop", "sys.boot_completed").strip() == b"1"
    subprocess.run([adb_path, "-s", device, "uninstall", "com.github.gemsnote.sharefixture"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    adb("install", apk)
    work = Path(tempfile.mkdtemp(prefix="gemsnote-attachment-open-"))
    run = uuid.uuid4().hex
    print(f"Evidence: {work}", flush=True)
    (work / "run.txt").write_text(run)
    log_path = work / "flutter.log"
    flutter = os.environ.get("FLUTTER_BIN", str(Path.home() / "opt/flutter/bin/flutter"))
    remote_xml = f"/sdcard/gemsnote-open-{run}.xml"

    def nodes(stage):
        adb("shell", "uiautomator", "dump", remote_xml)
        xml = adb("shell", "cat", remote_xml)
        (work / f"{stage}.xml").write_bytes(xml)
        return list(ET.fromstring(xml).iter("node"))

    process = None
    with log_path.open("w") as log:
        try:
            for index, kind in enumerate(["binary", "empty"], start=1):
                process = subprocess.Popen([
                    flutter, "test", "--no-pub", "--no-uninstall",
                    "integration_test/android_attachment_open_test.dart", "-d", device,
                    f"--dart-define=ATTACHMENT_OPEN_RUN={run}",
                    f"--dart-define=ATTACHMENT_OPEN_KIND={kind}",
                ], cwd=root, stdout=log, stderr=subprocess.STDOUT)
                assert process.wait(timeout=240) == 0, f"Flutter failed for {kind}; inspect {work}"
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    raw = adb("exec-out", "run-as", "com.github.gemsnote.sharefixture",
                              "cat", "files/received.jsonl")
                    try:
                        records = [json.loads(line) for line in raw.splitlines()]
                    except json.JSONDecodeError:
                        records = []
                    if len(records) >= index:
                        break
                    target = next((n for n in nodes(kind)
                                   if n.get("text") in {"Gemsnote test receiver", "Just once"}), None)
                    if target is not None:
                        xy = list(map(int, re.findall(r"\d+", target.get("bounds"))))
                        adb("shell", "input", "tap", str((xy[0] + xy[2]) // 2),
                            str((xy[1] + xy[3]) // 2))
                    time.sleep(0.3)
                else:
                    raise RuntimeError(f"Viewer did not receive {kind}; inspect {work}")
            raw = adb("exec-out", "run-as", "com.github.gemsnote.sharefixture",
                      "cat", "files/received.jsonl")
            (work / "received.jsonl").write_bytes(raw)
            records = [json.loads(line) for line in raw.splitlines()]
            assert len(records) == 2 and all("error" not in item for item in records), records
            for item, name, data in [
                (records[0], f"_open-{run}-附件_.bin", bytes([0, 1, 127, 128, 255])),
                (records[1], f"open-{run}-empty.bin", b""),
            ]:
                assert item["action"] == "android.intent.action.VIEW"
                assert item["type"] == "application/octet-stream"
                assert item["scheme"] == "content" and item["readGrant"]
                assert item["name"] == name
                assert base64.b64decode(item["bytes"]) == data
            adb("uninstall", "com.github.gemsnote.sharefixture")
            adb("shell", "rm", remote_xml)
            print("PASS: exact binary/empty files, safe names, content URI and read grants.")
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=15)
    print("Restore the normal lib/main.dart APK after this integration test.")


if __name__ == "__main__":
    main()
