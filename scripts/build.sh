#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(pwd)/build/MiniFocus.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p build/ModuleCache
clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=13.0 -c Sources/FocusUSB.c -o build/FocusUSB.o
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path build/ModuleCache \
  -import-objc-header Sources/FocusUSB.h Sources/FocusLogic.swift Sources/FramePerformance.swift Sources/TargetAppearance.swift Sources/ForegroundModel.swift Sources/VisionIdentity.swift Sources/CameraEngine.swift Sources/App.swift \
  build/FocusUSB.o -framework AppKit -framework AVFoundation -framework Vision -framework CoreImage -framework IOKit \
  -o "$APP/Contents/MacOS/MiniFocus"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '%s\n' "Built $APP"
