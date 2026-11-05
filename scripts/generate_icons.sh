#!/usr/bin/env bash
# Regenerate Flutter Android/iOS launcher icons from the project branding asset.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --help ]]; then
  echo 'Usage: bash scripts/generate_icons.sh'
  echo 'Requires ImageMagick (magick or convert). On Debian/Ubuntu: sudo apt install imagemagick; on macOS: brew install imagemagick.'
  echo 'Source: assets/branding/gemsnote.png; outputs: Android mipmaps and iOS AppIcon PNGs.'
  exit 0
fi
if [[ $# -ne 0 ]]; then echo 'Unknown arguments; use --help.' >&2; exit 2; fi
if command -v magick >/dev/null 2>&1; then
  image_cmd=magick
elif command -v convert >/dev/null 2>&1; then
  image_cmd=convert
else
  echo 'ImageMagick not found. Debian/Ubuntu: sudo apt install imagemagick; macOS: brew install imagemagick.' >&2
  exit 1
fi
source_icon="$project_dir/assets/branding/gemsnote.png"
[[ -f "$source_icon" ]] || { echo "Missing source: $source_icon" >&2; exit 1; }
res_dir="$project_dir/android/app/src/main/res"
ios_dir="$project_dir/ios/Runner/Assets.xcassets/AppIcon.appiconset"
background='#193b35'
opaque_icon() {
  local size="$1" output="$2" inset
  inset=$((size * 80 / 100))
  "$image_cmd" "$source_icon" -trim +repage -resize "${inset}x${inset}" \
    -background "$background" -gravity center -extent "${size}x${size}" \
    -alpha remove -alpha off -strip "PNG24:$output"
}
for spec in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r density size canvas <<< "$spec"
  directory="$res_dir/mipmap-$density"
  mkdir -p "$directory"
  opaque_icon "$size" "$directory/ic_launcher.png"
  # A 46dp square fits within Android's central 66dp safe circle.
  foreground=$((canvas * 46 / 108))
  "$image_cmd" "$source_icon" -trim +repage -resize "${foreground}x${foreground}" \
    -background none -gravity center -extent "${canvas}x${canvas}" -strip \
    "PNG32:$directory/ic_launcher_foreground.png"
done
for spec in 20:1:20 20:2:40 20:3:60 29:1:29 29:2:58 29:3:87 40:1:40 40:2:80 40:3:120 60:2:120 60:3:180 76:1:76 76:2:152 83.5:2:167 1024:1:1024; do
  IFS=: read -r points scale pixels <<< "$spec"
  opaque_icon "$pixels" "$ios_dir/Icon-App-${points}x${points}@${scale}x.png"
done
echo 'Android legacy/adaptive and iOS AppIcon PNGs regenerated.'
