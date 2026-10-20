#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_path="Resources/AppIcon.png"
iconset_path="$PWD/build/AppIcon.iconset"
mkdir -p "$iconset_path"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_path" --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_path" --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset_path" --output Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns"
