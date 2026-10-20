#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${OPENFILES_MLX:-0}" == "1" ]]; then
    ./scripts/build-mlx.sh OpenFilesChecks debug
    .build/mlx-xcode/Build/Products/Debug/OpenFilesChecks
else
    swift run --build-system native OpenFilesChecks
fi
swift run --build-system native OpenFilesCloudChecks
