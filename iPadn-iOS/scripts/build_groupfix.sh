#!/bin/bash
# Build the GroupFix dylib for iPhoneOS arm64:
#   build/groupfix/GroupFix.dylib   injected into a re-signed app so it finds
#                                   the App Groups / keychain groups it expects
#   build/groupfix/fishhook-BSD.txt license for the vendored fishhook
# Needs the iOS SDK (clang from Xcode); skipped on non-macOS like the other
# native components.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
src="$project_root/GroupFix"
output="$project_root/build/groupfix"

command -v xcrun >/dev/null 2>&1 || { echo "xcrun is required to build GroupFix." >&2; exit 1; }
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"

rm -rf "$output"
mkdir -p "$output"

# install_name is @rpath/GroupFix.dylib: it is copied into the target app's
# Frameworks folder, which is already on the rpath of an iOS app.
xcrun --sdk iphoneos clang -dynamiclib -fobjc-arc \
  -arch arm64 -isysroot "$sdk" -miphoneos-version-min=16.0 \
  -install_name "@rpath/GroupFix.dylib" \
  -framework Foundation -framework Security \
  "$src/GroupFix.m" "$src/fishhook.c" \
  -o "$output/GroupFix.dylib"

xcrun --sdk iphoneos strip -x "$output/GroupFix.dylib"
cp "$src/LICENSE-fishhook.txt" "$output/fishhook-BSD.txt"
xcrun --sdk iphoneos codesign --remove-signature "$output/GroupFix.dylib" 2>/dev/null || true
echo "GroupFix dylib built in $output"
ls -l "$output"
