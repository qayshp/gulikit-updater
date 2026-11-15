# GuliKit Updater for macOS

Experimental native updater for the GuliKit Elves 2 **NS58**, using macOS 27's
AccessoryAccess framework to claim the USB device and IOUSBHost to send the
firmware through USB mass storage Bulk-Only Transport.

The initial target is the known NS58 V3.7 firmware. Firmware is supplied at
runtime and verified against its known SHA-256. No GuliKit firmware is included
in this repository. NS59 / Elves 2 Pro is not supported.

## Status

Build and offline tests pass on macOS 27.2.1 / Xcode 27.2 / Swift 6.4.2. A
successful physical update on macOS is **not yet verified**. The earlier raw disk
implementation failed to trigger the updater; this experiment uses the new
exclusive USB handoff API.

The first signed launch was rejected by macOS: the Claim USB Accessory
entitlement requires an authorizing provisioning profile. A development
certificate alone and ad-hoc signing are insufficient. Automatic provisioning
currently reports **No Accounts** in this Mac's Xcode installation. Sign into
Xcode and select a developer team before running the hardware experiment.

Apple requires AccessoryAccess callers to be normal apps that appear in the
Dock, signed with `com.apple.developer.accessory-access.usb`. The USB operation
therefore runs in a minimal native app. A companion CLI handles offline work.

## Build

Requirements: macOS 27, the macOS 27 SDK in Xcode, and an Apple developer account
with access to the Claim USB Accessory capability.

1. Open `GuliKitUpdater.xcodeproj`.
2. In Xcode Settings > Accounts, add your Apple account.
3. Select the **GuliKitUpdater** app target, Signing & Capabilities, and your
   team. Automatic signing is enabled and Claim USB Accessory is in the
   entitlements file.
4. Run the shared **NativeUpdater** scheme.

Alternatively, after account setup:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/build-app.sh
open "dist/xcode/Build/Products/Debug/GuliKit Updater.app"
```

To compile without an account or provisioning (does not authorize USB access):

```sh
swift build
scripts/build-app.sh --unsigned
```

No root access is used by the new app. The app requests only the specific NS58
updater identity (`33fa:ff02`). This first experiment also requires serial
`115411`, the previously validated controller, and a clean `GuliKit 3.7` FAT12
baseline. Other units/versions remain future work.

## Hardware experiment

1. Start the signed app. With the controller off, connect a USB data cable,
   hold Setting (gear), then press Home.
2. In the macOS USB accessory menu, attach the controller to **GuliKit Updater**.
3. Click **Connect & Inspect**. macOS grants exclusive ownership; the app
   configures the USB interface and reads capacity and the FAT12 baseline.
   A passing result shows **USB CLAIM + BOT READ PASS** and the firmware label.
4. Click **Choose Firmware** and select the extracted official
   `NS58_Elves2_V3.7.bin`. Its size and SHA-256 must match the known release.
5. Click **Install V3.7**, review the confirmation, and select **Install Once**.
   The app sends the padded firmware in one WRITE(10) transaction and the FAT
   metadata in a second. It validates the BOT status of each transfer.
6. The app watches the USB registry for up to 60 seconds. An accessory detach
   notification alone does not prove physical disappearance. Confirm that the
   controller powers itself off automatically. Restart it normally, then
   re-enter update mode to inspect the version again.

No automatic retry or USB reset is performed. Any attempted transfer consumes
the current USB session; reconnect in update mode for another attempt. A
matching label after a same-version reinstall cannot independently prove that
flash pages changed. Preserve the transfer result and physical power-off
observation together.

## Offline CLI

```sh
.build/debug/gulikit verify /path/to/NS58_Elves2_V3.7.bin
.build/debug/gulikit plan --image /path/to/baseline.img --firmware /path/to/NS58_Elves2_V3.7.bin
swift test
```

`plan` accepts a regular image file and prints the proposed sector writes and
hashes. Tests cover malformed baselines, destination allocation, firmware
identity, and truncated image rejection. To run the captured Linux comparison
test, supply local fixtures (copyrighted firmware is not committed):

```sh
NS58_TEST_FIRMWARE=/path/to/NS58_Elves2_V3.7.bin \
NS58_TEST_LINUX_ROOT=/path/to/linux-root-final.bin swift test
```

## App Store direction

The initial target enables App Sandbox, USB access, and user-selected read-only
file access. No driver installation or privileged helper is involved. This
keeps an App Store path open, but provisioning, sandbox access to
`IOUSBHostInterface`, and App Review acceptance have not been verified. The
current experiment will establish whether the public framework supports this
updater's transfers inside the sandbox.

Optional follow-up features: official firmware download, additional controller
profiles, and comparing installed/available versions. The first priority is a
verified native update on the known NS58.

## Provenance

The FAT12 update plan comes from the July 2026 controller investigation:
Linux successfully wrote the padded firmware at LBA 10 (13 x 4096 bytes), then
the FAT copies and root metadata at LBA 1 (3 x 4096 bytes). The controller
powered off after those transfers. This repository reuses that plan while
replacing the macOS transport.

Official firmware page: https://www.gulikit.com/newsinfo/1071651.html

Apple API references:

- https://developer.apple.com/documentation/accessoryaccess/aausbaccessorymanager
- https://developer.apple.com/documentation/accessoryaccess/aausbaccessory
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-access.usb

This project is independent of GuliKit and is not endorsed by GuliKit or Apple.
