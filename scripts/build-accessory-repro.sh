#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---build}"
case "$mode" in --build|--unsigned|--run) ;; *) echo "usage: $0 [--build|--unsigned|--run]" >&2; exit 2;; esac
# Do not replace a running bundle or kill a client with an AccessoryAccess
# operation in flight. Separate DerivedData also preserves the updater build.
if pgrep -f '/AccessoryAccess Repro.app/Contents/MacOS/AccessoryAccess Repro' >/dev/null; then
    echo 'STOP: Quit AccessoryAccess Repro normally before rebuilding; no process was killed.' >&2
    exit 1
fi
derived_data="${GULIKIT_REPRO_DERIVED_DATA:-$HOME/Library/Caches/GuliKitAccessoryRepro/DerivedData}"
args=(-quiet -project GuliKitUpdater.xcodeproj -scheme AccessoryRepro -configuration Debug -derivedDataPath "$derived_data")
if [[ "$mode" == --unsigned ]]; then
    args+=(CODE_SIGNING_ALLOWED=NO)
else
    args+=(-allowProvisioningUpdates)
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"); fi
fi
xcodebuild "${args[@]}" build
app="$derived_data/Build/Products/Debug/AccessoryAccess Repro.app"
if [[ "$mode" != --unsigned ]]; then
    codesign --verify --strict "$app"
    test -f "$app/Contents/embedded.provisionprofile"
fi
echo "$app"
# Launch is intentionally explicit: registering another matching listener can
# affect routing, and no hardware experiment is implied by an offline build.
if [[ "$mode" == --run ]]; then /usr/bin/open "$app"; fi
