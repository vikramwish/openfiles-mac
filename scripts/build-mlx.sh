#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "EmbeddingGemma 2 requires an Apple Silicon Mac and full Xcode with Swift 6.3+." >&2
    exit 1
fi
scheme="${1:-OpenFiles}"
case "$scheme" in OpenFiles|OpenFilesChecks) ;; *) echo "Unsupported scheme: $scheme" >&2; exit 1 ;; esac
case "${2:-debug}" in
    debug) configuration=Debug ;;
    release) configuration=Release ;;
    *) echo "Configuration must be debug or release." >&2; exit 1 ;;
esac
# SwiftPM's command-line builder does not compile the Metal shaders required by MLX.
OPENFILES_MLX=1 xcodebuild build -scheme "$scheme" -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.build/mlx-xcode"
