#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
swift build --build-system native -c "$configuration" --product OpenFiles
app_path="$PWD/build/OpenFiles.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns || scripts/build-icon.sh -nt Resources/AppIcon.icns ]]; then
    ./scripts/build-icon.sh
fi
# Replace the executable atomically so rebuilding does not truncate a running app.
cp ".build/$configuration/OpenFiles" "$app_path/Contents/MacOS/OpenFiles.next"
mv "$app_path/Contents/MacOS/OpenFiles.next" "$app_path/Contents/MacOS/OpenFiles"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_path"
touch "$app_path"
echo "Built $app_path"
