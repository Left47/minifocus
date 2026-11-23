#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
  printf '%s\n' 'Usage: bash scripts/replay.sh VIDEO LABELS_JSON [REPORT_JSON]'
  exit 2
fi
mkdir -p build/ModuleCache
swiftc -swift-version 5 -O -module-cache-path build/ModuleCache \
  Sources/TargetAppearance.swift Sources/ForegroundModel.swift Sources/FramePerformance.swift Tests/replay.swift \
  -framework AVFoundation -o build/replay-test
build/replay-test "$@"
