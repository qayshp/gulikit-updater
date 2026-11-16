# USB flash-drive AccessoryAccess control

Prepared November 16, 2026. **Implementation and offline verification only; no
flash drive has been claimed or tested by this change.** No Apple feedback was
created or submitted.

The separate `FlashDriveRepro` scheme builds **USB Flash Drive Repro**, bundle
`com.qayshp.USBFlashDriveRepro`. It shares the close-only lifecycle with
AccessoryAccess Repro, but does not broaden the NS58 app's device filter.

## Scope and target safeguards

- The listener matches USB mass-storage BOT interfaces: class `08`, subclass
  `06`, protocol `50`. This is **not proof of flash-drive type**: some hard
  drives, SSDs, readers, and composite devices also match. UAS-only devices are
  deliberately not included.
- The known NS58 updater tuple `33fa:ff02` is excluded before accepting a
  candidate. No NS58 model inference is made for other USB tuples.
- Launch registers a listener only. Assignment does not automatically Claim.
  The user must confirm that the sole candidate is their spare flash drive,
  then click **Use This Drive for One Test** before the numbered buttons can
  become available.
- The pin captures one physical registry instance, the complete valid cached
  18-byte USB device descriptor, and optional cached product, serial, and
  location. Missing serial is displayed as missing, not treated as unique.
  Those values are checked before Claim/Reopen and again after AA open.
- Ambiguity, disconnect, or identity change revokes the pin for this launch.
  There is no automatic target selection, repinning, cycle, or retry.
- One explicit **Claim Once → Close Once → Reopen Once** cycle uses only
  `AAUSBAccessory.open`/`close` plus cached descriptor/IORegistry inspection.
  Close drops the old device reference and checks weak-reference clearance
  for at most two seconds; it never explicitly calls `destroy()`.
- There are no app-issued disk, filesystem, SCSI, BOT, reset, USB configuration,
  interface, pipe, or firmware commands. The only package dependency is pure
  `AccessoryReproCore`; the updater transport and downloader are not linked.

**This is not a promise of zero system-level storage activity.** macOS may
mount/read/write bookkeeping on a connected drive, and exclusive whole-device
handoff can unmount volumes or interrupt other functions. Use a spare drive
with no important data, close any files on it, and avoid a multifunction device.

## Build only

```sh
scripts/build-flash-drive-repro.sh
```

The script defaults to build-only, never kills apps, and refuses to replace a
running flash-drive repro bundle. Its separate default DerivedData is
`/Users/qayshp/Library/Caches/USBFlashDriveRepro/DerivedData` on this Mac. The
existing NS58 repro and updater bundles are not replaced. `--unsigned` is
compile-only; only an explicit `--run` also launches the signed app.

The signed development build uses the existing sandbox, USB-device, and
AccessoryAccess USB entitlement file. Its new app-specific provisioning
profile authorizes `com.apple.developer.accessory-access.usb`. There is no
network, file-selection, or temporary IOKit-class exception entitlement.
Development signing is not distribution/notarization or hardware validation.

## Setup now; stop before the test

1. Keep the Mac unlocked. Quit the normal **GuliKit Updater** and old
   **AccessoryAccess Repro** normally once idle; do not force-quit an operation.
   The NS58 controller is not needed for this control.
2. Open this exact new app (no build is necessary):

   ```sh
   open "/Users/qayshp/Library/Caches/USBFlashDriveRepro/DerivedData/Build/Products/Debug/USB Flash Drive Repro.app"
   ```

3. **Now connect one spare ordinary USB flash drive.** Close any files on it.
   Where practical disconnect other USB storage first, after safe eject.
4. In the macOS USB/accessory menu, open the entry for that flash drive's
   product/manufacturer and choose **Use with USB Flash Drive Repro**. Do not
   choose GuliKit Updater or AccessoryAccess Repro. Its entry may be the USB
   product name, not the Finder volume label.
5. Leave the new app open. **Stop here: do not tick the confirmation checkbox,
   pin the drive, or click any numbered button yet.** The test is deferred
   until the next explicitly authorized session.

If the app is absent from the USB menu or shows no candidate, stop and preserve
that observation. Do not substitute an SSD, format a drive, change matching to
all USB devices, or repeatedly reassign devices to make it appear.

## Later one-cycle test (not run or authorized by setup)

After confirming the displayed candidate with the user, pin the sole spare
drive and manually click each numbered action once, waiting for completion
between actions. Keep the app open after Reopen to observe delayed callbacks;
an immediate API PASS is not proof of stable ownership. Do not infer that a
flash-drive pass exonerates macOS or that a failure proves an Apple bug.

On failure, do not retry the same session. Copy the log, quit normally when
idle, return the device to this Mac, and safely eject mounted volumes before
any physical reconnect. **Copy Log** and unified subsystem
`com.qayshp.USBFlashDriveRepro` retain timestamps, callback delivery timing,
attachment generation, and API/weak-lifetime observations. They do not log file
contents or issue storage commands.

## Offline verification

`swift test --filter AccessoryReproCoreTests` passes 21 tests: fourteen lifecycle
tests plus seven target-gate tests for malformed identity, excluded NS58,
explicit/single-candidate confirmation, absent serial, changed identity,
revocation, and changed product snapshots. The signed flash-drive build and
strict signature check pass; the embedded profile carries the AA entitlement.
The original NS58 repro is separately compile-checked without changing its
running bundle. No UI launch or hardware-cycle validation is claimed.
