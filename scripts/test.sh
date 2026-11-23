#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
swiftc -swift-version 5 -module-cache-path build/ModuleCache Sources/FocusLogic.swift Tests/main.swift -o build/logic-tests
build/logic-tests
if [[ "${1:-}" == "--hardware" ]]; then
  clang -Wall -Wextra -Werror -ISources Tests/hardware.c Sources/FocusUSB.c -framework IOKit -framework CoreFoundation -o build/hardware-test
  build/hardware-test
fi
