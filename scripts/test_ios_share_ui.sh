#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/with_xcode.sh bash scripts/test_ios_share_ui.sh <simulator-id>" >&2
  exit 64
fi
device_id="$1"
mobile_root="$(cd "$(dirname "$0")/.." && pwd)"
sources="$mobile_root/integration_test/ios_native_ui"
work_dir="${IOS_UI_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-share-ui.XXXXXX")}"
mkdir -p "$work_dir"
work_dir="$(cd "$work_dir" && pwd)"
test_log="$work_dir/share-ui.log"

# CocoaPods already includes xcodeproj; support both ordinary Ruby gems and
# Homebrew's isolated CocoaPods environment without installing more packages.
ruby_bin="${RUBY_BIN:-ruby}"
if ! "$ruby_bin" -e 'require "xcodeproj"' >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    export GEM_HOME="$(brew --prefix cocoapods)/libexec"
    ruby_bin="$(brew --prefix ruby)/bin/ruby"
  fi
fi
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" "$mobile_root/build/ios/iphonesimulator/Runner.app"
if ! group_dir="$(xcrun simctl get_app_container "$device_id" com.github.gemsnote group.com.github.gemsnote)"; then
  echo "Build the simulator app WITHOUT --no-codesign to enable App Group access." >&2
  exit 1
fi
GEMSNOTE_RESTORE_LANGUAGE="$(python3 - "$group_dir" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Library/Preferences/group.com.github.gemsnote.plist'
value = plistlib.loads(path.read_bytes()).get('gemsnote.language', 'system') if path.exists() else 'system'
if value not in ('system', 'zh', 'en'):
    raise SystemExit('Invalid existing native language preference')
print(value)
PY
)"
export GEMSNOTE_RESTORE_LANGUAGE
"$ruby_bin" "$sources/create_project.rb" "$work_dir"

python3 -m http.server 8765 --bind 127.0.0.1 --directory "$sources/fixture" \
  > "$work_dir/fixture-server.log" 2>&1 &
server_pid="$!"
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
if ! kill -0 "$server_pid" 2>/dev/null; then
  cat "$work_dir/fixture-server.log" >&2
  exit 1
fi

if ! xcodebuild test -project "$work_dir/SharingUI.xcodeproj" -scheme SharingUITests \
  -destination "platform=iOS Simulator,id=$device_id" -parallel-testing-enabled NO \
  -derivedDataPath "$work_dir/DerivedData" CODE_SIGNING_ALLOWED=NO > "$test_log" 2>&1; then
  tail -60 "$test_log" >&2
  echo "UI test artifacts: $work_dir" >&2
  exit 1
fi

python3 - "$group_dir" "$GEMSNOTE_RESTORE_LANGUAGE" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Library/Preferences/group.com.github.gemsnote.plist'
value = plistlib.loads(path.read_bytes()).get('gemsnote.language', 'system') if path.exists() else 'system'
if value != sys.argv[2]:
    raise SystemExit('Language test did not restore the original native preference')
print('PASS original native language preference restored')
PY

xcrun swiftc -swift-version 5 "$mobile_root/ios/Shared/SharedTextStore.swift" \
  "$sources/VerifyInbox.swift" -o "$work_dir/verify-inbox"
fixture_container="$(xcrun simctl get_app_container "$device_id" com.github.gemsnote.SharingFixture data)"
"$work_dir/verify-inbox" "$group_dir" "$test_log" "$fixture_container"
echo "UI test artifacts: $work_dir"
