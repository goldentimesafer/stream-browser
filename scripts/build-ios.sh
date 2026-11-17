#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
output="$root/build"
mkdir -p "$output"
package="$(mktemp -d "$output/package.XXXXXXXX")"
trap 'rm -rf -- "$package"' EXIT
xcodebuild -version
swiftc "$root/StreamBrowser/MediaPolicy.swift" "$root/Tests/MediaPolicyChecks.swift" -o "$output/media-policy-checks"
"$output/media-policy-checks"
swiftc "$root/StreamBrowser/MediaPolicy.swift" "$root/StreamBrowser/MediaStore.swift" \
  "$root/Tests/MediaStoreChecks.swift" -o "$output/media-store-checks"
"$output/media-store-checks"
swiftc "$root/StreamBrowser/MediaPolicy.swift" "$root/StreamBrowser/MediaStore.swift" \
  "$root/StreamBrowser/DownloadRules.swift" "$root/Tests/DownloadRulesChecks.swift" -o "$output/download-rules-checks"
"$output/download-rules-checks"

xcodebuild -project StreamBrowser.xcodeproj -scheme StreamBrowser \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$package/DerivedData" CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" build

app="$package/DerivedData/Build/Products/Release-iphoneos/StreamBrowser.app"
# The iOS 18.5 runtime has no libswiftWebKit.dylib; a hard link to it aborts the app at launch.
linked_libraries="$(otool -L "$app/StreamBrowser")"
if [[ "$linked_libraries" == *libswiftWebKit* ]]; then
  echo "error: StreamBrowser links libswiftWebKit.dylib. Use the Objective-C WebKit methods (__find, __callAsyncJavaScript)." >&2
  exit 1
fi

mkdir "$package/Payload"
ditto "$app" "$package/Payload/StreamBrowser.app"
ditto -c -k --keepParent "$package/Payload" "$package/StreamBrowser-unsigned.ipa"
mv -f "$package/StreamBrowser-unsigned.ipa" "$output/StreamBrowser-unsigned.ipa"
(
  cd "$output"
  shasum -a 256 StreamBrowser-unsigned.ipa | tee StreamBrowser-unsigned.ipa.sha256
  {
    printf 'Commit: %s\n' "$(git -C "$root" rev-parse HEAD)"
    printf 'Event: %s\n' "${GITHUB_EVENT_NAME:-local}"
    printf 'Build: %s\n' "${BUILD_NUMBER:-1}"
    xcodebuild -version
  } > StreamBrowser-build.txt
)
