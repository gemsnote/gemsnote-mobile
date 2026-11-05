#!/usr/bin/env python3
"""Import exactly the five records verified by test_android_share_ui.py."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith("emulator-"):
        raise SystemExit("Usage: test_android_share_import.py emulator-5554 records.json")
    device = sys.argv[1]
    records = json.loads(Path(sys.argv[2]).read_text())
    ids = [record["id"] for record in records]
    assert len(ids) == len(set(ids)) == 5
    assert all(re.fullmatch("[0-9a-f]{24}", value) for value in ids)
    adb_path = str(Path.home() / "Library/Android/sdk/platform-tools/adb")

    def adb(*args):
        return subprocess.check_output([adb_path, "-s", device, *args], timeout=30)

    def queue():
        prefs = ET.fromstring(adb(
            "shell", "run-as", "com.github.gemsnote",
            "cat", "shared_prefs/shared_text_inbox.xml"
        ))
        return json.loads(next(n.text for n in prefs if n.get("name") == "queue"))

    assert adb("shell", "getprop", "ro.kernel.qemu").strip() == b"1"
    assert queue() == records, "Inbox differs from verified fixture; refusing to claim anything"
    assert all(not r.get("accountKey") for r in records)
    work = Path(tempfile.mkdtemp(prefix="gemsnote-share-import-android-"))
    print(f"Evidence: {work}", flush=True)
    flutter = os.environ.get("FLUTTER_BIN", str(Path.home() / "opt/flutter/bin/flutter"))
    with (work / "flutter.log").open("w") as log:
        result = subprocess.run([
            flutter, "test", "--no-pub", "--no-uninstall",
            "integration_test/android_share_import_test.dart", "-d", device,
            "--dart-define=SHARE_IMPORT_IDS=" + ",".join(ids),
        ], cwd=Path(__file__).resolve().parents[1], stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Import failed; inspect {work}; do not clear unrelated shares")
    assert queue() == [], "Acknowledged records remain"
    assert not adb("shell", "run-as", "com.github.gemsnote",
                   "ls", "files/shared_resources").strip(), "Originals were not removed"
    print("PASS: five native claims/imports/retries; queue and original files are empty.")
    print("Rebuild/install the normal lib/main.dart APK after device testing.")


if __name__ == "__main__":
    main()
