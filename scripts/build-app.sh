#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
swift build --build-system native -c "$configuration"
app_path="$PWD/build/OpenFiles.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp ".build/$configuration/OpenFiles" "$app_path/Contents/MacOS/OpenFiles"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
echo "Built $app_path"
