#!/bin/bash
set -euo pipefail
mobile_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-share-tests.XXXXXX")"
trap 'rm -rf "$test_output"' EXIT
swiftc -swift-version 5 -module-cache-path "$test_output/module-cache" \
  "$mobile_root/ios/Shared/SharedTextStore.swift" \
  "$mobile_root/ios/SharedTests/SharedTextStoreTests.swift" \
  -o "$test_output/share-store-tests"
"$test_output/share-store-tests"
