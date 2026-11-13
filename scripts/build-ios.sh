#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
output="$root/build"
mkdir -p "$output"
xcodebuild -version
swiftc "$root/StreamBrowser/MediaPolicy.swift" "$root/Tests/MediaPolicyChecks.swift" -o "$output/media-policy-checks"
"$output/media-policy-checks"

xcodebuild -project StreamBrowser.xcodeproj -scheme StreamBrowser \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$output/DerivedData" CODE_SIGNING_ALLOWED=NO build

package="$(mktemp -d "$output/package.XXXXXXXX")"
trap 'rm -rf -- "$package"' EXIT
mkdir "$package/Payload"
ditto "$output/DerivedData/Build/Products/Release-iphoneos/StreamBrowser.app" "$package/Payload/StreamBrowser.app"
ditto -c -k --keepParent "$package/Payload" "$package/StreamBrowser-unsigned.ipa"
mv -f "$package/StreamBrowser-unsigned.ipa" "$output/StreamBrowser-unsigned.ipa"
shasum -a 256 "$output/StreamBrowser-unsigned.ipa"
