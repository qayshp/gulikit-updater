#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-project GuliKitUpdater.xcodeproj -scheme NativeUpdater -configuration Debug
      -derivedDataPath dist/xcode)
if [[ "${1:-}" == "--unsigned" ]]; then
    args+=(CODE_SIGNING_ALLOWED=NO)
elif [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    args+=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
    echo 'Set DEVELOPMENT_TEAM to your Apple developer team ID, or use --unsigned to compile only.' >&2
    echo 'First add your Apple account in Xcode > Settings > Accounts.' >&2
    exit 2
fi
xcodebuild "${args[@]}" build
app="$PWD/dist/xcode/Build/Products/Debug/GuliKit Updater.app"
if [[ "${1:-}" != "--unsigned" ]]; then
    codesign --verify --strict "$app"
    test -f "$app/Contents/embedded.provisionprofile"
fi
echo "$app"
