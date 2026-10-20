#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ "${OPENFILES_MLX:-0}" == "1" ]]; then
    ./scripts/build-mlx.sh OpenFiles "$configuration"
    case "$configuration" in debug) xcode_configuration=Debug ;; release) xcode_configuration=Release ;; esac
    bin_path="$PWD/.build/mlx-xcode/Build/Products/$xcode_configuration"
else
    swift build --build-system native -c "$configuration" --product OpenFiles
    bin_path="$PWD/.build/$configuration"
fi
app_path="$PWD/build/OpenFiles.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns || scripts/build-icon.sh -nt Resources/AppIcon.icns ]]; then
    ./scripts/build-icon.sh
fi
cp "$bin_path/OpenFiles" "$app_path/Contents/MacOS/OpenFiles.next"
mv "$app_path/Contents/MacOS/OpenFiles.next" "$app_path/Contents/MacOS/OpenFiles"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
if [[ "${OPENFILES_MLX:-0}" == "1" ]]; then
    shopt -s nullglob
    for resource in "$bin_path"/*.bundle; do
        ditto "$resource" "$app_path/Contents/Resources/$(basename "$resource")"
    done
fi
# A stable signing identity keeps macOS folder-access and Keychain grants across rebuilds;
# ad-hoc signing looks like a new app every time, so the system re-asks for permission.
identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^[[:space:]]*[0-9]*) [A-F0-9]* "\(.*\)".*/\1/p' | head -1)"
if [[ -z "$identity" ]]; then identity="-"; fi
codesign --force --deep --sign "$identity" "$app_path"
touch "$app_path"
echo "Built $app_path"
