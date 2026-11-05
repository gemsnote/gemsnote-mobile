#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/with_xcode.sh bash scripts/test_ios_share_import.sh <simulator-id>" >&2
  exit 64
fi
mobile_root="$(cd "$(dirname "$0")/.." && pwd)"
device_id="$1"
flutter_bin="${FLUTTER_BIN:-flutter}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-share-import.XXXXXX")"
run_id="$(python3 -c 'import uuid; print(uuid.uuid4().hex[:22])')"
xcrun simctl bootstatus "$device_id" -b
group_dir="$(xcrun simctl get_app_container "$device_id" com.github.gemsnote group.com.github.gemsnote)"
xcrun swiftc -swift-version 5 "$mobile_root/ios/Shared/SharedTextStore.swift" \
  "$mobile_root/integration_test/ios_native_ui/SeedImport.swift" -o "$work_dir/seed-import"
"$work_dir/seed-import" "$group_dir" "$run_id" "$mobile_root/assets/images/gemsnote_s.png"
echo "Import fixture prefix: $run_id; artifacts: $work_dir"
# Flutter requires the package directory. This subshell does not change callers' cwd.
(
  cd "$mobile_root"
  "$flutter_bin" test --no-pub --no-uninstall integration_test/ios_share_import_test.dart \
    -d "$device_id" --dart-define="SHARE_IMPORT_RUN=$run_id" \
    > "$work_dir/flutter-test.log" 2>&1
) || {
  tail -60 "$work_dir/flutter-test.log" >&2
  echo "Failure: inspect the test log and any remaining fixture records; do not clear unrelated shares." >&2
  exit 1
}
tail -12 "$work_dir/flutter-test.log"
echo "Rebuild/install lib/main.dart after integration testing to restore the ordinary application."
