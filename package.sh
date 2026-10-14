#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
./build.sh

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
archive="Blackout-v${version}-macos-arm64.zip"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent build/Blackout.app "dist/${archive}"
(cd dist && shasum -a 256 "${archive}" > SHA256SUMS)
print "Packaged dist/${archive}"
