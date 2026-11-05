#!/usr/bin/env python3
"""Validate real cross-app URI grants on a disposable, signed-out emulator.

Requires the ordinary Gemsnote APK and a fixture APK from
build_android_share_fixture.sh. Leaves five verified records for subsequent
native import testing; never clears an existing inbox.
"""
import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith("emulator-"):
        raise SystemExit("Usage: test_android_share_ui.py emulator-5554 fixture.apk")
    device, apk = sys.argv[1:]
    root = Path(__file__).resolve().parents[1]
    adb_path = str(Path.home() / "Library/Android/sdk/platform-tools/adb")
    adb_command = [adb_path, "-s", device]

    def adb(*args):
        return subprocess.check_output(adb_command + list(args), timeout=30)

    def queue():
        names = adb("shell", "run-as", "com.github.gemsnote", "ls", "shared_prefs").decode().split()
        if "shared_text_inbox.xml" not in names:
            return []
        xml = adb("shell", "run-as", "com.github.gemsnote",
                  "cat", "shared_prefs/shared_text_inbox.xml")
        prefs = ET.fromstring(xml)
        return json.loads(next((n.text for n in prefs if n.get("name") == "queue"), "[]"))

    assert adb("shell", "getprop", "ro.kernel.qemu").strip() == b"1"
    assert not queue(), "Refusing to modify a non-empty share inbox"
    prefs = ET.fromstring(adb("shell", "run-as", "com.github.gemsnote",
                             "cat", "shared_prefs/note_widget.xml"))
    assert not any(n.get("name") == "account" and n.text for n in prefs), "Sign out first"
    # Only the disposable sender is replaced; the target app is never uninstalled.
    subprocess.run(adb_command + ["uninstall", "com.github.gemsnote.sharefixture"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    adb("install", apk)
    work = Path(tempfile.mkdtemp(prefix="gemsnote-share-ui-"))
    run = uuid.uuid4().hex
    (work / "run.txt").write_text(run)
    print(f"Evidence: {work}", flush=True)

    def nodes(stage):
        remote = "/sdcard/gemsnote-share-ui.xml"
        adb("shell", "uiautomator", "dump", remote)
        xml = adb("shell", "cat", remote)
        (work / f"{stage}.xml").write_bytes(xml)
        return list(ET.fromstring(xml).iter("node"))

    def click_text(text, stage):
        deadline = time.monotonic() + 30
        while True:
            found = next((
                n for n in nodes(stage) if n.get("text", "").casefold() == text.casefold()
            ), None)
            if found is not None:
                bounds = list(map(int, re.findall(r"\d+", found.get("bounds"))))
                adb("shell", "input", "tap",
                    str((bounds[0] + bounds[2]) // 2),
                    str((bounds[1] + bounds[3]) // 2))
                return
            if time.monotonic() > deadline:
                raise RuntimeError(f"Missing {text}; see {work}")

    def share(invalid):
        kind = "invalid" if invalid else "valid"
        adb("shell", "am", "start", "-W", "-n",
            "com.github.gemsnote.sharefixture/.SharingActivity",
            "--es", "fixture-run", run)
        click_text(f"Share {kind} batch", kind + "-source")
        click_text("Gemsnote", kind + "-chooser")

    adb("shell", "am", "force-stop", "com.github.gemsnote")
    share(False)
    deadline = time.monotonic() + 25
    records = []
    while time.monotonic() < deadline:
        records = queue()
        if len(records) == 5:
            break
        assert len(records) in (0, 5), "Partial batch published"
        time.sleep(0.2)
    assert len(records) == 5, records
    assert all(not r.get("accountKey") for r in records)
    (work / "records.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
    originals = {
        "image.png": ("image", (root / "assets/images/gemsnote_s.png").read_bytes()),
        "data.bin": ("attachment", bytes([0, 1, 2, 127, 128, 255])),
        "animation.gif": ("attachment", base64.b64decode(
            "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        )),
    }
    for name, (kind, expected) in originals.items():
        record = next(r for r in records if r["resourceName"] == name)
        assert record["resourceKind"] == kind
        assert record["resourceSize"] == len(expected)
        actual = adb("exec-out", "run-as", "com.github.gemsnote",
                     "cat", "files/shared_resources/" + record["id"])
        assert actual == expected, f"Changed original bytes: {name}"
    text = next(r for r in records if r["title"] == "body.txt")
    assert text["text"] == f"Shared file {run}\n正文 😀"
    assert text["resourceKind"] == "" and text["resourceSize"] == 0
    assert any(r["text"] == f"Caption {run}" and not r["resourceKind"] for r in records)
    resource_ids = {r["id"] for r in records if r["resourceKind"]}

    adb("shell", "am", "force-stop", "com.github.gemsnote")
    adb("shell", "am", "start", "-W", "-n", "com.github.gemsnote/.MainActivity")
    assert queue() == records, "Persisted batch changed across app restart"
    share(True)
    # The production reader rejects late batches at 15 seconds. Observe the
    # whole window, not just a snapshot taken before asynchronous file reads.
    deadline = time.monotonic() + 17
    while time.monotonic() < deadline:
        assert queue() == records, "Invalid batch partially changed the inbox"
        time.sleep(0.25)
    resources = set(adb("shell", "run-as", "com.github.gemsnote",
                        "ls", "files/shared_resources").decode().split())
    assert resources == resource_ids, f"Invalid batch leaked files: {resources - resource_ids}"
    print("PASS: granted URI batch, PNG/bin/GIF bytes, UTF-8 text/caption, restart, atomic rejection.")
    print(f"Five records retained for import verification: {work / 'records.json'}")


if __name__ == "__main__":
    main()
