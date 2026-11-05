#!/bin/bash
set -euo pipefail

# Native Dart build hooks may discard DEVELOPER_DIR while preserving PATH.
# Keep developer-directory selection local to this command, including xcrun
# calls from those hooks, without changing xcode-select or patching the SDK.
if [[ $# -eq 0 ]]; then
  echo "Usage: DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer bash scripts/with_xcode.sh <command> [args...]" >&2
  exit 64
fi

developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
  echo "Set DEVELOPER_DIR to the Contents/Developer directory of a full Xcode installation." >&2
  exit 1
fi

shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/gemsnote-xcode.XXXXXX")"
cleanup() {
  rm -f -- "$shim_dir/xcrun"
  rmdir -- "$shim_dir"
}
trap cleanup EXIT

# %q quotes paths containing spaces or shell characters for the generated Bash
# wrapper. Call the absolute system xcrun to avoid recursing through PATH.
printf '#!/bin/bash\nexport DEVELOPER_DIR=%q\nexec /usr/bin/xcrun "$@"\n' \
  "$developer_dir" > "$shim_dir/xcrun"
chmod 700 "$shim_dir/xcrun"

DEVELOPER_DIR="$developer_dir" PATH="$shim_dir:$PATH" "$@"
