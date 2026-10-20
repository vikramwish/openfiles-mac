#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ "${OPENFILES_MLX:-0}" == "1" ]]; then
    ./scripts/build-mlx.sh OpenFiles "$configuration"
    case "$configuration" in debug) xcode_configuration=Debug ;; release) xcode_configuration=Release ;; esac
    bin_path="$PWD/.build/mlx-xcode/Build/Products/$xcode_configuration"
else
    swift build --build-system native -c "$configuration"
    bin_path="$PWD/.build/$configuration"
fi
app_path="$PWD/build/OpenFiles.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/OpenFiles" "$app_path/Contents/MacOS/OpenFiles"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
if [[ "${OPENFILES_MLX:-0}" == "1" ]]; then
    # Xcode compiles MLX's Metal shaders into package resource bundles.
    # Keep those and tokenizer resources available after moving the app.
    shopt -s nullglob
    for resource in "$bin_path"/*.bundle; do
        ditto "$resource" "$app_path/Contents/Resources/$(basename "$resource")"
    done
fi
codesign --force --deep --sign - "$app_path"
echo "Built $app_path"
