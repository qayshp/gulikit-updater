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

**One native macOS V3.7 reinstall triggered the controller's normal update
completion behavior on the validated NS58.** On November 15, 2026, both firmware
and metadata WRITE(10) commands completed with matching, successful BOT status
and zero residue. The USB device disappeared about 2.6 seconds later, before
the app released its claim, and the user confirmed automatic physical power-off.
No automatic retry or second install occurred.

Before installing, inspection passed with capacity 119 × 4096 bytes and the
validated FAT12 baseline labeled `GuliKit 3.7`. The first post-restart inspection
failed on the READ CAPACITY data stage with `0xe00002e8` (data overrun). After
a normal start, power-off, and fresh update-mode session, read-only inspection
passed again with the expected capacity, clean FAT12 baseline, and `GuliKit 3.7`
label. No second install was performed. A same-version reinstall does not
independently establish that every flash page was rewritten. See the
[hardware validation record](docs/hardware-validation-2026-11-15.md).

The user later reported another successful manual reinstall after rear-OFF
recovery from repeated button use. That additional install was not instrumented
by the agent; it is recorded separately in the initialization investigation.

This result uses a Debug-only, class-scoped sandbox exception. The original
permissions failed to create IOUSBHostInterface (`0xe00002c9`); interface
creation works with the exception. An earlier existing session timed out on
its first command, while a fresh physical update-mode session passed. Inspection
and initialization still need reliability work; this is not a production-ready
or broadly compatible updater.

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

No root access is used by the new app. The app requests the captured updater
USB fingerprint (`33fa:ff02`), not a proven model-unique identity. This first experiment also requires serial
`115411`, the previously validated controller, and a clean `GuliKit 3.7` FAT12
baseline. Serial uniqueness is not established. Other units/versions remain future work.
Installation additionally requires physical-label confirmation that the
controller is **NS58 / Elves 2**, not NS59 / Elves 2 Pro. See
[model identification and limits](docs/model-identification.md).

### Debug sandbox experiment

Debug builds use `Config/GuliKitUpdater-Debug.entitlements`, which adds only
`AppleUSBHostFrameworkInterfaceClient` to the documented
`com.apple.security.temporary-exception.iokit-user-client-class` array. App
Sandbox stays enabled. This permission is scoped to a user-client class, not a
vendor/product pair; the AccessoryAccess matching and application identity
checks still restrict this app's connection path to the validated NS58.
Release builds retain `Config/GuliKitUpdater.entitlements` without the exception.

On the tested macOS build the ordinary USB sandbox entitlement permits legacy
USB user clients but not this IOUSBHost framework client. Adding the exception
changed the observed failure from interface creation to a later bulk-transfer
timeout; a fresh physical update-mode session subsequently passed inspection.
This is a local diagnostic result, not proof of a complete updater or App Store
approval.

### Initialization reliability work

The app now invalidates closed/released sessions before updating readiness,
tracks attachment generations across asynchronous inspection, and defers Quit
while USB work is in flight. Capacity inspection receives one endpoint-sized
packet while keeping its declared SCSI data length at eight bytes, so unexpected
status packets can be diagnosed without accepting them as capacity data.
The proven firmware-write transaction is unchanged and is never automatically
retried. See [USB initialization hardening](docs/usb-initialization-hardening.md)
for the changes, offline checks, hardware evidence, and remaining hypotheses.

### Recovery and action guards

After a USB failure, unexpected ownership loss, Release, or installation
attempt, the affected physical USB registry instance cannot be inspected/reset
or installed again. A same-ID logical reconnect does not clear the gate. The
main app asks for rear **OFF**, then **Setting + Home**, native Mac volume
initialization, and reattachment of a new USB instance. The cable can remain
connected. Release deliberately requires a fresh session because ordinary
same-instance reclaim is still unreliable; the separate repro below preserves
that sequence for controlled diagnostics.

Recovery records survive app relaunch within the same kernel boot when its
boot-session namespace is available. They are discarded across boots, since
registry IDs are not durable device identities. If the namespace cannot be
read, the log explicitly reports that only the current-process gate is active.
There is no Clear Error / Retry button that silently reuses a failed session.
Invalid local firmware or download failures do not quarantine a healthy USB
session. Method-level and modal-target guards supplement disabled buttons.
Copy Log includes timestamps for reporting a failure.

### Minimal non-flashing AccessoryAccess reproduction

The separate **AccessoryRepro** Xcode scheme builds **AccessoryAccess Repro**:
explicit **Claim Once → Close Once → Reopen Once**, with callback and cleanup
timing. It does not configure USB, create a storage interface, send SCSI or reset
commands, load firmware, or read/write controller sectors. Its only package
dependency is the separate pure `AccessoryReproCore` state machine.

```sh
scripts/build-accessory-repro.sh
```

The default is build-only, uses separate DerivedData, and never kills the
updater. Do not run both apps for the same controller or start a hardware cycle
implicitly. See the [reproduction guide](docs/accessoryaccess-close-reopen-repro.md)
for the explicit launch/test sequence, safety gates, and evidence boundaries.

The first authorized AA-only hardware cycle reproduced delayed ownership loss:
Reopen returned successfully, then a logical disconnect arrived about 93 ms
later while the physical USB device remained present. The app latched off with
no retry. Configuration/interface/SCSI/firmware code was absent from this
test, so those paths are not required to trigger the observed symptom. This is
not yet proof of a framework defect. See the
[AA-only result](docs/accessoryaccess-repro-result-2026-11-15.md).

The current reproduction is a **close-only control**: it removes the original
variant's explicit device destruction after AA close and observes old-wrapper
release through a weak reference before enabling Reopen. This tests whether
the extra cleanup contributes to the ownership loss; it does not assume the
cause is an Apple framework bug. See the reproduction guide for its bounded,
non-flashing test and inconclusive-result conditions.

That close-only control was hardware-tested once on November 16 and still
lost ownership shortly after successful Reopen, despite confirmed old-wrapper
weak-reference clearance about six seconds beforehand. The extra explicit
`destroy()` is therefore not required for this symptom. It remains a suspected
lifecycle/platform interaction, not a confirmed Apple defect. See the
[close-only result](docs/accessoryaccess-close-only-result-2026-11-16.md).

A separate **FlashDriveRepro** scheme now builds **USB Flash Drive Repro** for
an ordinary spare BOT USB flash drive. It keeps the same non-flashing,
close-only lifecycle, excludes the NS58 tuple, and requires explicit pinning of
one cached USB identity before any action. It does not issue storage commands.
This control is built and offline-tested, **not hardware-tested**. See the
[setup-only instructions and safety limits](docs/usb-flash-drive-repro.md);
preparing it does not start a Claim/Close/Reopen cycle.

## Hardware experiment

1. Start the signed app. With the controller off, connect a USB data cable,
   hold Setting (gear), then press Home.
2. In the macOS USB accessory menu, attach the controller to **GuliKit Updater**.
3. Click **Connect & Inspect**. macOS grants exclusive ownership; the app
   configures the USB interface and reads capacity and the FAT12 baseline.
   A passing result shows **USB CLAIM + BOT READ PASS** and the firmware label.
   Inspection does not send storage-write commands, but it does reconfigure
   USB and can temporarily remove the mounted volume from Finder. A failed
   inspection keeps Install disabled and leaves its error visible.
4. Click **Download V3.7** to retrieve and verify the supported release, or
   click **Choose Firmware** and select the extracted official
   `NS58_Elves2_V3.7.bin`. Its size and SHA-256 must match the known release.
   Download automatically selects the verified BIN; a second file selection
   is unnecessary. The window shows its full path and the installation blocker.
5. Check the controller's physical model label and tick the **NS58 / Elves 2**
   confirmation. The checkbox is cleared on attachment/session changes; a
   matching USB/FAT profile alone is not a model guarantee. Click **Install
   V3.7**, review the confirmation, and select **Install Once**.
   The app sends the padded firmware in one WRITE(10) transaction and the FAT
   metadata in a second. It validates the BOT status of each transfer.
6. The app watches the USB registry for up to 60 seconds. An accessory detach
   notification alone does not prove physical disappearance. Confirm that the
   controller powers itself off automatically. Restart it normally, then
   re-enter update mode to inspect the version again.

No automatic retry or USB device/port reset is performed. Any attempted firmware transfer consumes
the current USB session; reconnect in update mode for another attempt. A
matching label after a same-version reinstall cannot independently prove that
flash pages changed. Preserve the transfer result and physical power-off
observation together.

### Explicit non-flashing transport-reset diagnostic

**Reset Transport & Inspect…** is separate from normal Connect & Inspect and
Install. After its confirmation it attempts one standard Bulk-Only Transport
class reset, clears the bulk IN halt, then clears the bulk OUT halt, before the
first inspection command. This changes transport state but sends no firmware
or filesystem writes; it is not a USB port/device reset.

The policy permits it only once per transport, before any SCSI command or
firmware write. The attempt is consumed before its first control request. Any
failure closes the transport and stops without retry or fallback. An interface
configuration failure happens before the reset request and must not be reported
as a reset failure or success.

On 2026-11-15 this explicit action completed once on the validated NS58: class
reset and both clear-halt operations passed, followed by valid capacity/status
and FAT12 inspection of `GuliKit 3.7`. It followed a rear-OFF/update-mode restart
while assigned to macOS, a confirmed native volume mount, and handoff to the
same running updater. No firmware was selected or written. This does not prove
that reset was necessary, that the sequence is repeatable, or that the earlier
configuration and release/reclaim failures are fixed.

A subsequent one-shot Release Controller → ordinary Connect & Inspect test
completed accessory close, explicit device-client destruction, and old-wrapper
deallocation, but still received a logical AccessoryAccess disconnect during
inspection. Capacity/status had already succeeded and the physical device
remained present. The stale result was correctly discarded and Install stayed
disabled. No further reset or firmware write was performed. See the
[initialization investigation](docs/usb-initialization-hardening.md) for the
phase-by-phase evidence and limits.

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
file access. No driver installation or privileged helper is involved.
Development provisioning, listener registration, and downloading inside the
sandbox are verified. Debug interface creation, capacity reads, and FAT12
baseline inspection passed on a fresh device session with the narrow temporary
exception described above. One live native firmware transaction then completed
with the expected physical power-off. Post-restart inspection reliability and
App Review acceptance remain unresolved; Release access without the exception
is not established.

Apple documents the temporary-exception mechanism, but requires justification
and a corresponding reported-issue number when requesting an exception for App
Store submission. The experiment does not establish review acceptance, and the
Release configuration deliberately does not include it. See
[Apple's temporary-exception entitlement reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).

Next priorities are reliable initialization and post-restart inspection on the
known NS58, followed by resolving the sandbox exception's distribution path.
Optional follow-up features include additional controller profiles and comparing
installed/available versions.

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
