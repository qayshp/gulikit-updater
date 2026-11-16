# Minimal AccessoryAccess close/reopen reproduction

`AccessoryAccess Repro` is a separate ordinary macOS 27 app, bundle identifier
`com.qayshp.GuliKitAccessoryRepro`, for isolating the ownership transition from
the firmware updater. It is not a firmware updater and does not depend on
`USBTransport`, `NS58Core`, or `FirmwareDownload`.

One authorized hardware cycle using the original close-plus-explicit-destroy
variant on November 15, 2026 reproduced delayed logical
ownership loss: Claim and Close passed; Reopen returned successfully, but about
93 ms later AccessoryAccess reported disconnect while the physical registry
remained present. The final state was recoveryRequired, not a stable API-cycle
pass. No storage or reset command was sent by the repro app. See the
[captured result and limits](accessoryaccess-repro-result-2026-11-15.md).

The current **close-only variant** removes every explicit `device.destroy()`
call, including failure/quit cleanup. It is a control for the redundant cleanup
in the original variant, not yet evidence of a fix. Framework/ARC destruction
may still occur automatically when objects deallocate.

One authorized close-only hardware cycle on November 16 also reproduced the
ownership loss. AA close succeeded, the old wrapper's weak reference cleared,
and Reopen succeeded about six seconds later; the framework entered a logical
disconnect callback about 4 ms after Reopen PASS. The final state was stopped
and no retry occurred. See the [close-only result](accessoryaccess-close-only-result-2026-11-16.md).

## Deliberately small scope

The app registers a `33fa:ff02` listener, accepts only devices matching the
previously validated USB serial profile `115411`, and exposes three one-shot
actions:

1. **Claim Once** calls `AAUSBAccessory.open` and holds the returned device.
2. **Close Once** awaits `AAUSBAccessory.close`, drops the app's strong device
   reference, then observes its weak reference for at most two seconds. Reopen
   remains disabled until that weak reference clears and the attachment is
   still current. No explicit `destroy()` call is made.
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
held final client, logging close completion and scope ending without an explicit
destroy; quitting and window
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
  ordering only in the original November 15 variant. The current close-only
  variant intentionally excludes explicit destruction to isolate that variable.
- A weak reference that does not clear within two seconds yields an
  **inconclusive lifetime control; Reopen not attempted**. Framework caching of
  an invalidated wrapper is possible; this is not proof of a leak or failed
  close. Weak-reference clearance also does not establish completion of all
  internal framework or kernel cleanup.

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
The close-only gate additionally rejects completion while the old wrapper is
still retained; fourteen reproduction-state tests pass offline.

Relevant public contracts were checked in the installed macOS SDK:
`AAUSBAccessory.h` says completed close invalidates all returned device clients
and permits reopen; `AAUSBAccessoryListener.h` documents ordered callback-queue
delivery and console-session detach/reconnect; `AAUSBAccessoryManager.h`
requires a normal Dock app and the AccessoryAccess entitlement; and
`IOUSBHostObject.h` documents idempotent destroy. The original variant awaited
explicit destruction on a detached worker, outside a completion handler. The
current control relies on AA close plus ordinary object lifetime instead.

For the separately built ordinary-drive control, see
[USB Flash Drive Repro](usb-flash-drive-repro.md). Its explicit target-pin gate
does not broaden this NS58-only product. The setup checkpoint stops before
pinning or running a hardware cycle.
