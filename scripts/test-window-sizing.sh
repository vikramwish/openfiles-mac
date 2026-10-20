#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/openfiles-window-checks.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/OpenFiles/WindowHosting.swift Tests/WindowSizingChecks/main.swift -o "$test_dir/WindowSizingChecks"
"$test_dir/WindowSizingChecks" --automatic-sizing-control
"$test_dir/WindowSizingChecks"
