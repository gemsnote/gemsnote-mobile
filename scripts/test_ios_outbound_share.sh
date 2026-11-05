#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'Usage: with_xcode.sh bash test_ios_outbound_share.sh <simulator-id>' >&2; exit 64; }
device_id="$1"
mobile_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-outbound-ios.XXXXXX")"
export OUTBOUND_SHARE_RUN="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
echo "$OUTBOUND_SHARE_RUN" > "$work_dir/run.txt"
echo "Evidence: $work_dir"
flutter="${FLUTTER_BIN:-$HOME/opt/flutter/bin/flutter}"
ruby_bin="${RUBY_BIN:-ruby}"
if ! "$ruby_bin" -e 'require "xcodeproj"' >/dev/null 2>&1; then
  export GEM_HOME="$(brew --prefix cocoapods)/libexec"
  ruby_bin="$(brew --prefix ruby)/bin/ruby"
fi
xcrun simctl bootstatus "$device_id" -b
(
  cd "$mobile_root"
  "$flutter" build ios --simulator --debug --target=integration_test/ios_outbound_share_fixture.dart \
    "--dart-define=OUTBOUND_SHARE_RUN=$OUTBOUND_SHARE_RUN"
) > "$work_dir/flutter-build.log" 2>&1
xcrun simctl install "$device_id" "$mobile_root/build/ios/iphonesimulator/Runner.app"
"$ruby_bin" "$mobile_root/integration_test/ios_outbound_share_ui/create_project.rb" "$work_dir"
if ! xcodebuild test -project "$work_dir/OutboundUI.xcodeproj" -scheme OutboundUITests \
  -destination "platform=iOS Simulator,id=$device_id" -parallel-testing-enabled NO \
  -derivedDataPath "$work_dir/DerivedData" CODE_SIGNING_ALLOWED=NO > "$work_dir/ui.log" 2>&1; then
  tail -65 "$work_dir/ui.log" >&2
  echo "Inspect $work_dir and restore the normal app." >&2
  exit 1
fi
xcrun simctl uninstall "$device_id" com.github.gemsnote.ReceiverHost
echo "PASS local receiver verified text and binary originals; evidence: $work_dir"
echo 'Rebuild/install the normal lib/main.dart app after this test.'
