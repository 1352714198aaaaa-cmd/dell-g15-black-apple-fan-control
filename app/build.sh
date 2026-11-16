#!/bin/bash
set -e
cd "$(dirname "$0")"
mkdir -p FanCtl.app/Contents/MacOS FanCtl.app/Contents/Resources
cp Info.plist FanCtl.app/Contents/Info.plist
cp AppIcon.icns FanCtl.app/Contents/Resources/
clang -O2 -o FanCtl.app/Contents/Resources/smcread smcread.c -framework IOKit -framework CoreFoundation
swiftc -O -o FanCtl.app/Contents/MacOS/FanCtl main.swift -framework Cocoa -framework SwiftUI -framework IOKit
echo "built: app/FanCtl.app"
