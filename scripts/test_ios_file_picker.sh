#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: with_xcode.sh bash test_ios_file_picker.sh <simulator-id>" >&2; exit 64; }
device_id="$1"
mobile_root="$(cd "$(dirname "$0")/.." && pwd)"
sources="$mobile_root/integration_test/ios_file_picker_ui"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-picker-ios.XXXXXX")"
export FILE_PICKER_RUN="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
echo "$FILE_PICKER_RUN" > "$work_dir/run.txt"
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
  "$flutter" build ios --simulator --debug \
    --target=integration_test/ios_file_picker_fixture.dart \
    "--dart-define=FILE_PICKER_RUN=$FILE_PICKER_RUN"
) > "$work_dir/flutter-build.log" 2>&1
xcrun simctl install "$device_id" "$mobile_root/build/ios/iphonesimulator/Runner.app"
"$ruby_bin" "$sources/create_project.rb" "$work_dir"
if ! xcodebuild test -project "$work_dir/PickerUI.xcodeproj" -scheme PickerUITests \
  -destination "platform=iOS Simulator,id=$device_id" -parallel-testing-enabled NO \
  -derivedDataPath "$work_dir/DerivedData" CODE_SIGNING_ALLOWED=NO \
  > "$work_dir/ui.log" 2>&1; then
  tail -70 "$work_dir/ui.log" >&2
  echo "Restore the normal Flutter app after inspecting $work_dir" >&2
  exit 1
fi
fixture_container="$(xcrun simctl get_app_container "$device_id" com.github.gemsnote.PickerFiles data)"
python3 - "$fixture_container" "$FILE_PICKER_RUN" <<'PY'
import base64, json, pathlib, sys
folder = pathlib.Path(sys.argv[1]) / 'Documents'
run = sys.argv[2]
md = '# 原文 📝\n\n换行与 **格式**\n'
html = '<p>原文 &amp; emoji 📝</p>\n<table><tr><td>保留</td></tr></table>'
for kind, content in [('md', md), ('html', html)]:
    text = (folder / f'gemsnote-{run}-{kind}.{"rtf" if kind == "html" else "md"}').read_text()
    if kind == 'md':
        assert text.startswith('---\ntitle: ') and text.endswith(md)
    else:
        assert text.startswith(r'{\rtf1') and r'\u' in text and r'\trowd' in text
archive = json.loads((folder / f'gemsnote-{run}-gemsnote.gemsnote').read_bytes())
assert archive['note']['content'] == md
assert base64.b64decode(archive['resources'][0]['bytes']) == bytes([0, 1, 127, 128, 255])
files = list(folder.glob(f'gemsnote-{run}-*'))
assert len(files) == 3, 'Cancel unexpectedly created another file'
for file in files:
    file.unlink()
print('PASS exact source and binary originals; no extra cancellation output')
PY
echo "Restore the normal Flutter app; evidence: $work_dir"
