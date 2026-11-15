#!/bin/bash
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk macosx --show-sdk-path)
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
clang -arch x86_64 -mkernel -fapple-kext -nostdinc++ -fno-exceptions -fno-rtti \
  -fno-builtin -fno-common -O2 -I"$KH" -I"$SDK/usr/include" -DKERNEL -DKEXT \
  -c FanProbe.cpp -o FanProbe.o
mkdir -p FanProbe.kext/Contents/MacOS
cp Info.plist FanProbe.kext/Contents/Info.plist
clang -arch x86_64 -mkernel -nostdlib -Wl,-kext -o FanProbe.kext/Contents/MacOS/FanProbe FanProbe.o
echo "built: kext/FanProbe.kext"
