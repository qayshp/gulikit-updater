# Minimal AccessoryAccess close/reopen reproduction

`AccessoryAccess Repro` is a separate ordinary macOS 27 app, bundle identifier
`com.qayshp.GuliKitAccessoryRepro`, for isolating the ownership transition from
the firmware updater. It is not a firmware updater and does not depend on
`USBTransport`, `NS58Core`, or `FirmwareDownload`.

One authorized hardware cycle on November 15, 2026 reproduced delayed logical
ownership loss: Claim and Close passed; Reopen returned successfully, but about
93 ms later AccessoryAccess reported disconnect while the physical registry
remained present. The final state was recoveryRequired, not a stable API-cycle
pass. No storage or reset command was sent by the repro app. See the
[captured result and limits](accessoryaccess-repro-result-2026-11-15.md).

## Deliberately small scope

The app registers a `33fa:ff02` listener, accepts only devices matching the
previously validated USB serial profile `115411`, and exposes three one-shot
actions:

1. **Claim Once** calls `AAUSBAccessory.open` and holds the returned device.
2. **Close Once** awaits `AAUSBAccessory.close`, then awaits the returned
   device's idempotent `destroy()` on a detached worker. Each return is logged.
3. **Reopen Once** calls `AAUSBAccessory.open` again for the current attachment.

It does **not** select a USB configuration, create an IOUSBHostInterface, open
bulk pipes, issue SCSI commands, read or write controller sectors, send a BOT or
USB device reset, load firmware, or retry any operation automatically. Launch
only registers a listener; a claim requires its explicit button.

The USB tuple and serial restrict the accepted fingerprint. They are not proof
of a unique physical unit or that those identifiers distinguish NS58 from every
other GuliKit model. This app is intentionally unsuitable as a general GuliKit
detection utility.

## Build without touching the running updater

```sh
./scripts/build-accessory-repro.sh
```

The default is build-only. It uses the `AccessoryRepro` Xcode scheme and
`~/Library/Caches/GuliKitAccessoryRepro/DerivedData`, separate from the updater.
It refuses to replace a running reproduction bundle and never kills either
app. `--unsigned` performs a compile-only build; that bundle cannot establish
the provisioned AccessoryAccess behavior. `--run` builds and explicitly opens
the signed app, but is a separate step from an offline build and should be
performed only when a hardware experiment is intended.

The repro entitlement file includes only sandbox, USB-device access, and
AccessoryAccess USB. It has no network, selected-file, or temporary interface
user-client exception. Xcode automatic development signing uses the existing
project team, but the new bundle requires its own provisioned App ID/profile.
Successful signing is not evidence that a hardware operation has passed.

## One bounded hardware test

Do not run this alongside an updater installation. Quit the normal updater
normally only when it is idle. Keep the console unlocked. Use the controller's
rear **OFF** button, then hold **Setting**, press **Home**, and release Setting;
the cable can remain connected. A fresh registry instance is required after a
failed test. Optionally first assign the controller to **Use with this Mac**
and confirm the normal Finder volume as the native-initialized baseline.

Open the signed repro and assign **Gulikit → Use with AccessoryAccess Repro** in
the macOS USB menu. Invoke each numbered action once, in order. Wait for its
completion before the next action. Reopen is never scheduled automatically.

After a failure or disconnect, the current registry session is latched off.
An immediate logical disconnect/reconnect with the same registry ID does not
clear that latch. Use rear OFF and Setting + Home to establish a genuinely new
device session. The latch is deliberately in memory; relaunching does not prove
physical recovery and must not be used as a retry mechanism. Quit closes any
held final client, logging close and destroy completion; quitting and window
closure are blocked while an operation or registration is in flight.

**Copy Log** copies the timestamped app log to the clipboard. Unified logs use
subsystem `com.qayshp.GuliKitAccessoryRepro` and categories `reproduction` and
`accessory-events`. They include callback source uptime, serial FIFO delivery
sequence, main-actor delivery delay, attachment generation, physical-registry
presence, and API-phase completions. No raw memory addresses or firmware
payloads are logged. Console workspace events are correlation only, not a
complete screen-lock detector.

## Evidence boundaries

- A final **AA CLAIM → CLOSE → REOPEN API PASS** proves only that these public
  API operations completed for that attachment generation. It does not prove
  interface opening, BOT/SCSI reads, or flashing works.
- An AccessoryAccess disconnect during an operation invalidates its result,
  even if the physical registry entry remains present. No stale result becomes
  a pass, and no control is re-enabled for an immediate same-ID reconnect.
- Before publishing a claim/reopen pass, the app independently checks that the
  physical registry entry is still present and that the returned client's
  IOService registry ID matches the captured accessory. A queued disconnect
  callback cannot make an already-observed disappearance count as success.
- If this AA-only sequence passes but the updater's interface/read sequence
  fails, the additional configuration/interface/storage path is a variable to
  isolate next; the result does not by itself identify a macOS bug.
- The app-level lifecycle matches the investigated explicit close/destroy
  ordering, but omits transport setup and commands intentionally. This is not
  yet a claim that the minimal reproduction reproduces the hardware failure.

## Offline checks

```sh
swift test --filter ReproStateTests
./scripts/build-accessory-repro.sh --unsigned
./scripts/build-accessory-repro.sh
```

The pure `AccessoryReproCore` tests cover ordered one-shot actions, duplicate
button attempts, wrong ordering, API failure, stale generation rejection, and
failure retention across a same-registry logical reconnect. The app's Xcode
dependency graph contains only its app target and `AccessoryReproCore`.

Relevant public contracts were checked in the installed macOS SDK:
`AAUSBAccessory.h` says completed close invalidates all returned device clients
and permits reopen; `AAUSBAccessoryListener.h` documents ordered callback-queue
delivery and console-session detach/reconnect; `AAUSBAccessoryManager.h`
requires a normal Dock app and the AccessoryAccess entitlement; and
`IOUSBHostObject.h` documents idempotent destroy. Destroy must not be called
from a framework completion handler, so this repro awaits it on a detached
worker instead.
