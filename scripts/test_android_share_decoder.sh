#!/bin/bash
set -euo pipefail
mobile_root="$(cd "$(dirname "$0")/.." && pwd)"
java_root="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-android-share-tests.XXXXXX")"
trap 'rm -rf "$test_output"' EXIT
"$java_root/bin/javac" --release 17 -encoding UTF-8 -d "$test_output" \
  "$mobile_root/android/app/src/main/java/com/github/gemsnote/SharedTextDecoder.java" \
  "$mobile_root/android/app/src/main/java/com/github/gemsnote/SharedResourceStore.java" \
  "$mobile_root/android/app/src/test/java/com/github/gemsnote/SharedTextDecoderTest.java" \
  "$mobile_root/android/app/src/test/java/com/github/gemsnote/SharedResourceStoreTest.java"
"$java_root/bin/java" -cp "$test_output" com.github.gemsnote.SharedTextDecoderTest
"$java_root/bin/java" -cp "$test_output" com.github.gemsnote.SharedResourceStoreTest
