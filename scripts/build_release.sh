#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build_release.sh [android|ios|all]

Build signed release artifacts into release/.

Android requires:
  ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD,
  ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD

iOS requires a configured Apple signing team and a full Xcode installation.
Set DEVELOPER_DIR when Xcode is not selected system-wide. Optional:
  IOS_EXPORT_METHOD=app-store|ad-hoc|development|enterprise
  IOS_EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist

Common optional variables:
  FLUTTER_BIN=/path/to/flutter
  RELEASE_DIR=/path/to/output
  GEMSNOTE_LINK_HOST=notes.example
  SKIP_CHECKS=1
EOF
}

target="${1:-all}"
case "$target" in
  android|ios|all) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 64
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
cd "$project_dir"

flutter_bin="${FLUTTER_BIN:-$HOME/opt/flutter/bin/flutter}"
if [[ ! -x "$flutter_bin" ]]; then
  flutter_bin="$(command -v flutter || true)"
fi
if [[ -z "$flutter_bin" || ! -x "$flutter_bin" ]]; then
  echo "Flutter was not found. Set FLUTTER_BIN to the Flutter executable." >&2
  exit 1
fi

version_line="$(sed -n 's/^version: \([0-9][0-9.]*\)+\([0-9][0-9]*\)$/\1 \2/p' pubspec.yaml)"
if [[ -z "$version_line" ]]; then
  echo "pubspec.yaml must contain version: MAJOR.MINOR.PATCH+BUILD." >&2
  exit 1
fi
read -r version build_number <<< "$version_line"

release_dir="${RELEASE_DIR:-$project_dir/release}"

temporary_xcconfig=""
cleanup() {
  if [[ -n "$temporary_xcconfig" ]]; then
    rm -f -- "$temporary_xcconfig"
  fi
}
trap cleanup EXIT

validate_link_host() {
  local host="${GEMSNOTE_LINK_HOST:-}"
  if [[ -z "$host" ]]; then
    return
  fi
  if [[ ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
     [[ "$host" == *..* ]] || [[ "$host" == *.-* ]] || [[ "$host" == *-.* ]]; then
    echo "GEMSNOTE_LINK_HOST must be a hostname without a scheme, port, or path." >&2
    exit 1
  fi
}

validate_link_host

if [[ "${SKIP_CHECKS:-0}" != "1" ]]; then
  "$flutter_bin" pub get --enforce-lockfile
  "$flutter_bin" analyze --no-pub
  "$flutter_bin" test --no-pub
fi

artifacts=()

build_android() {
  local required value source destination
  for required in ANDROID_KEYSTORE_PATH ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
    value="${!required:-}"
    if [[ -z "$value" ]]; then
      echo "Missing Android signing variable: $required" >&2
      exit 1
    fi
  done
  if [[ ! -f "$ANDROID_KEYSTORE_PATH" ]]; then
    echo "Android keystore does not exist: $ANDROID_KEYSTORE_PATH" >&2
    exit 1
  fi
  if [[ -n "${GEMSNOTE_LINK_HOST:-}" ]]; then
    export ORG_GRADLE_PROJECT_GEMSNOTE_LINK_HOST="$GEMSNOTE_LINK_HOST"
  fi
  # --no-pub also skips regenerating release registrants in the pinned Flutter.
  # A previous pub get/test includes dev-only plugins such as integration_test.
  "$flutter_bin" build apk --release
  "$flutter_bin" build appbundle --release
  mkdir -p -- "$release_dir"
  source="build/app/outputs/flutter-apk/app-release.apk"
  destination="$release_dir/gemsnote-$version-android.apk"
  cp -- "$source" "$destination"
  artifacts+=("$destination")
  source="build/app/outputs/bundle/release/app-release.aab"
  destination="$release_dir/gemsnote-$version-android.aab"
  cp -- "$source" "$destination"
  artifacts+=("$destination")
}

find_xcode() {
  local candidate
  if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    return
  fi
  candidate="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
    DEVELOPER_DIR="$candidate"
    export DEVELOPER_DIR
    return
  fi
  shopt -s nullglob
  for candidate in /Volumes/*/Applications/Xcode.app/Contents/Developer /Applications/Xcode.app/Contents/Developer; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
      DEVELOPER_DIR="$candidate"
      export DEVELOPER_DIR
      shopt -u nullglob
      return
    fi
  done
  shopt -u nullglob
  echo "A full Xcode installation was not found. Set DEVELOPER_DIR." >&2
  exit 1
}

build_ios() {
  local source destination export_method
  local ipa_args
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "iOS release builds require macOS." >&2
    exit 1
  fi
  find_xcode
  ipa_args=(build ipa --release)
  if [[ -n "${IOS_EXPORT_OPTIONS_PLIST:-}" ]]; then
    if [[ ! -f "$IOS_EXPORT_OPTIONS_PLIST" ]]; then
      echo "Export options plist does not exist: $IOS_EXPORT_OPTIONS_PLIST" >&2
      exit 1
    fi
    ipa_args+=("--export-options-plist=$IOS_EXPORT_OPTIONS_PLIST")
  else
    export_method="${IOS_EXPORT_METHOD:-app-store}"
    case "$export_method" in
      app-store|ad-hoc|development|enterprise) ;;
      *)
        echo "Unsupported IOS_EXPORT_METHOD: $export_method" >&2
        exit 1
        ;;
    esac
    ipa_args+=("--export-method=$export_method")
  fi
  if [[ -n "${GEMSNOTE_LINK_HOST:-}" ]]; then
    temporary_xcconfig="$(mktemp "${TMPDIR:-/tmp}/gemsnote-release.XXXXXX")"
    printf '#include "%s"\nGEMSNOTE_LINK_HOST = %s\n' \
      "$project_dir/ios/Flutter/Release.xcconfig" "$GEMSNOTE_LINK_HOST" \
      > "$temporary_xcconfig"
    export XCODE_XCCONFIG_FILE="$temporary_xcconfig"
  fi
  DEVELOPER_DIR="$DEVELOPER_DIR" bash "$script_dir/with_xcode.sh" \
    "$flutter_bin" "${ipa_args[@]}"
  shopt -s nullglob
  local ipa_files=(build/ios/ipa/*.ipa)
  shopt -u nullglob
  if [[ ${#ipa_files[@]} -ne 1 ]]; then
    echo "Expected exactly one IPA in build/ios/ipa; found ${#ipa_files[@]}." >&2
    exit 1
  fi
  source="${ipa_files[0]}"
  destination="$release_dir/gemsnote-$version-ios.ipa"
  mkdir -p -- "$release_dir"
  cp -- "$source" "$destination"
  artifacts+=("$destination")
}

case "$target" in
  android) build_android ;;
  ios) build_ios ;;
  all) build_android; build_ios ;;
esac

checksum_file="$release_dir/SHA256SUMS"
: > "$checksum_file"
for artifact in "${artifacts[@]}"; do
  if command -v sha256sum >/dev/null 2>&1; then
    (cd -- "$release_dir" && sha256sum "$(basename -- "$artifact")") >> "$checksum_file"
  else
    digest="$(shasum -a 256 "$artifact" | awk '{print $1}')"
    printf '%s  %s\n' "$digest" "$(basename -- "$artifact")" >> "$checksum_file"
  fi
done

printf 'Built Gemsnote %s+%s:\n' "$version" "$build_number"
printf '  %s\n' "${artifacts[@]}" "$checksum_file"
