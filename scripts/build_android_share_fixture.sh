#!/bin/bash
set -euo pipefail
mobile_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
java_root="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
tools="$sdk/build-tools/36.0.0"
android_jar="$sdk/platforms/android-36/android.jar"
work="$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-share-fixture.XXXXXX")"
mkdir "$work/classes" "$work/dex"
source_dir="$mobile_root/integration_test/android_share_fixture"
"$java_root/bin/javac" --release 17 -encoding UTF-8 -classpath "$android_jar" \
  -d "$work/classes" "$source_dir/SharingActivity.java" "$source_dir/FixtureProvider.java" \
  "$source_dir/ReceivingActivity.java"
JAVA_HOME="$java_root" "$tools/d8" --lib "$android_jar" --min-api 26 \
  --output "$work/dex" "$work/classes/com/github/gemsnote/sharefixture/"*.class
"$tools/aapt2" link -I "$android_jar" --manifest "$source_dir/AndroidManifest.xml" -o "$work/unsigned.apk"
python3 - "$work" "$mobile_root" <<'PY'
import sys, zipfile
from pathlib import Path
work, root = map(Path, sys.argv[1:])
with zipfile.ZipFile(work / "unsigned.apk", "a") as apk:
    apk.write(work / "dex/classes.dex", "classes.dex")
    apk.write(root / "assets/images/gemsnote_s.png", "assets/image.png")
PY
"$tools/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
"$java_root/bin/keytool" -genkeypair -keystore "$work/fixture.keystore" \
  -storepass android -keypass android -alias fixture -keyalg RSA -validity 30 \
  -dname "CN=Disposable Gemsnote Test" > "$work/signing.log" 2>&1
JAVA_HOME="$java_root" "$tools/apksigner" sign --ks "$work/fixture.keystore" \
  --ks-pass pass:android --key-pass pass:android --out "$work/fixture.apk" "$work/aligned.apk"
echo "$work/fixture.apk"
