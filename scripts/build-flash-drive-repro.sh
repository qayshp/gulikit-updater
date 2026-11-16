#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---build}"
case "$mode" in --build|--unsigned|--run) ;; *) echo "usage: $0 [--build|--unsigned|--run]" >&2; exit 2;; esac
# Never replace or terminate a client that may be inside an AccessoryAccess
# operation. This product and its DerivedData are separate from both NS58 apps.
if pgrep -f '/USB Flash Drive Repro.app/Contents/MacOS/USB Flash Drive Repro' >/dev/null; then
    echo 'STOP: Quit USB Flash Drive Repro normally before rebuilding; no process was killed.' >&2
    exit 1
fi
derived_data="${GULIKIT_FLASH_REPRO_DERIVED_DATA:-$HOME/Library/Caches/USBFlashDriveRepro/DerivedData}"
args=(-quiet -project GuliKitUpdater.xcodeproj -scheme FlashDriveRepro -configuration Debug -derivedDataPath "$derived_data")
if [[ "$mode" == --unsigned ]]; then
    args+=(CODE_SIGNING_ALLOWED=NO)
else
    args+=(-allowProvisioningUpdates)
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"); fi
fi
xcodebuild "${args[@]}" build
app="$derived_data/Build/Products/Debug/USB Flash Drive Repro.app"
if [[ "$mode" != --unsigned ]]; then
    codesign --verify --strict "$app"
    test -f "$app/Contents/embedded.provisionprofile"
fi
echo "$app"
# Build-only is the default. Launch requires an explicit flag and does not
# imply permission to assign, claim, close, or reopen any attached drive.
if [[ "$mode" == --run ]]; then /usr/bin/open "$app"; fi
