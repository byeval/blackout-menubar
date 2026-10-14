#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"

if [[ "$(uname -m)" != "arm64" ]]; then
  print -u2 "Blackout currently supports Apple Silicon Macs only."
  exit 1
fi

export MACOSX_DEPLOYMENT_TARGET=13.0
make -C Vendor/m1ddc fclean
make -C Vendor/m1ddc binary

app="${PWD}/build/Blackout.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 Sources/Blackout.swift \
  -framework AppKit -framework Carbon -framework IOKit \
  -o "$app/Contents/MacOS/Blackout"
cp Vendor/m1ddc/m1ddc "$app/Contents/Helpers/m1ddc"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/Helpers/m1ddc"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
print "Built $app"
