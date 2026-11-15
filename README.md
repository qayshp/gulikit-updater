# GuliKit Updater for macOS

Experimental native updater for the GuliKit Elves 2 **NS58**, using macOS 27's
AccessoryAccess framework to claim the USB device and IOUSBHost to send the
firmware through USB mass storage Bulk-Only Transport.

The initial target is the known NS58 V3.7 firmware. Firmware is supplied at
runtime and verified against its known SHA-256. No GuliKit firmware is included
in this repository. NS59 / Elves 2 Pro is not supported.

## Status

Build and offline tests pass on macOS 27.2.1 / Xcode 27.2 / Swift 6.4.2. The
signed sandboxed app launches, its provisioning profile authorizes Claim USB
Accessory, and AccessoryAccess successfully registers the NS58 listener.
Downloading and verifying V3.7 inside the sandbox has also passed.

A successful physical update on macOS is **not yet verified**. No NS58 was
attached during this runtime check. The earlier raw disk implementation failed
to trigger the updater; this experiment uses the new exclusive USB handoff API.

Claim USB Accessory requires an authorizing provisioning profile. A development
certificate alone and ad-hoc signing are insufficient. Automatic provisioning
works after selecting the developer team and registering this Mac for development.

Apple requires AccessoryAccess callers to be normal apps that appear in the
Dock, signed with `com.apple.developer.accessory-access.usb`. The USB operation
therefore runs in a minimal native app. A companion CLI handles offline work.

## Build

Requirements: macOS 27, the macOS 27 SDK in Xcode, and an Apple developer account
with access to the Claim USB Accessory capability.

1. Open `GuliKitUpdater.xcodeproj`.
2. In Xcode Settings > Accounts, add your Apple account.
3. In the left Project navigator, click the top-level blue **GuliKitUpdater**
   project icon. In the editor's **TARGETS** list select **GuliKitUpdater**, then
   click **Signing & Capabilities** across the top. Choose your **Team** in the
   Signing section. If Xcode reports that this Mac is not registered, click
   **Register Device**. Automatic signing is enabled and Claim USB Accessory is
   already present. No separate capability needs to be added.
4. Run the shared **NativeUpdater** scheme.

Alternatively, after account setup:

```sh
scripts/build-app.sh
open "$HOME/Library/Caches/GuliKitUpdater/DerivedData/Build/Products/Debug/GuliKit Updater.app"
```

The script uses the team configured in the app target. Override it when needed
with `DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/build-app.sh`. Select the shared
**NativeUpdater** scheme; the similarly named **GuliKitUpdater** Swift package
scheme does not produce the provisioned app bundle.

The script puts generated products under `~/Library/Caches/GuliKitUpdater`
because iCloud/File Provider can add Finder metadata to bundles under Documents
and cause strict signature verification to fail. Xcode's normal Run action uses
its own DerivedData directory and is also suitable. Set `GULIKIT_DERIVED_DATA`
to choose a different local build directory.

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
4. Click **Download V3.7** to retrieve and verify the supported release, or
   click **Choose Firmware** and select the extracted official
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
.build/debug/gulikit download --directory /existing/output/directory
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

## Firmware download

The downloader retrieves the **supported V3.7 release**, rather than assuming
every future release is compatible with this experimental write plan. GuliKit's
official download endpoint may require browser verification, so the current
source is the [TousLesDrivers mirror](https://www.touslesdrivers.com/index.php?v_code=84388&v_page=23).
The downloaded ZIP is byte-identical to the original official package retained
from the earlier investigation:

```text
ZIP SHA-256: b2a447203f7329e8981050717cfc1aa143a00dd18d50015e9cfdad389e645784
BIN SHA-256: 486c308e857b24adde6e7b623af67c8d0a74b6038f57ffc41ea7e2b94683e1eb
```

The download is limited to 512 KiB while receiving bytes, restricts HTTPS
redirects to the pinned source, checks the ZIP hash before parsing, extracts
only the expected BIN into memory, and checks its hash again. The CLI writes
the BIN atomically without replacing an existing file or symlink. The app
saves it in its sandbox cache and selects it for installation. Downloading
does not open or write a controller.

ZIP parsing uses the MIT-licensed
[ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.20),
pinned in both SwiftPM and Xcode lockfiles. Firmware itself is not committed.

Eight additional tests cover download URL policy, archive rejection, hash
validation, fixed output naming, and preservation of existing files/symlinks.
To include the pinned archive extraction test, also set:

```sh
NS58_TEST_ARCHIVE=/path/to/NS58_Elves2_V3.7.zip swift test
```

The CLI and the signed sandboxed app both completed a real HTTPS download and
verified the resulting BIN. The app displayed `NS58 V3.7 downloaded and verified.`

## App Store direction

The initial target enables App Sandbox, USB access, and user-selected read-only
file access. No driver installation or privileged helper is involved. This
keeps an App Store path open. Development provisioning, listener registration,
and downloading inside the sandbox are verified. Sandbox access to
`IOUSBHostInterface`, live controller transfers, and App Review acceptance remain
unverified. The hardware experiment will establish whether the public framework
supports this updater's transfers inside the sandbox.

Optional follow-up features: additional controller profiles and comparing
installed/available versions. The first priority is a
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
