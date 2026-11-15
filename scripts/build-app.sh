#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# File Provider can add FinderInfo to bundles built under synced Documents.
# Keep signed products in a local cache, as Xcode does with DerivedData.
derived_data="${GULIKIT_DERIVED_DATA:-$HOME/Library/Caches/GuliKitUpdater/DerivedData}"
args=(-project GuliKitUpdater.xcodeproj -scheme NativeUpdater -configuration Debug
      -derivedDataPath "$derived_data")
if [[ "${1:-}" == "--unsigned" ]]; then
    args+=(CODE_SIGNING_ALLOWED=NO)
elif [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    args+=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
    # Use the team selected in the app target's Signing & Capabilities panel.
    args+=(-allowProvisioningUpdates)
fi
xcodebuild "${args[@]}" build
app="$derived_data/Build/Products/Debug/GuliKit Updater.app"
if [[ "${1:-}" != "--unsigned" ]]; then
    codesign --verify --strict "$app"
    test -f "$app/Contents/embedded.provisionprofile"
fi
echo "$app"
