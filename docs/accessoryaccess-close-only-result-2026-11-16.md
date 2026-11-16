# Close-only control reproduced ownership loss after Reopen

## Authorized scope

The user approved removing the extra explicit `destroy()` call, followed by
one non-flashing Claim → Close → Reopen test, and reported keeping the Mac
unlocked. The close-only build passed fourteen focused reproduction-state
tests and its signed Debug build before launch. The previous repro was quit
normally; no normal updater process remained running. The user prepared a
fresh rear-OFF/Setting+Home session and assigned it to AccessoryAccess Repro.

Environment: macOS 27.2.1 (26B131), arm64; Xcode 27.2 (27B52).
Source: `6b539e1`, bundle `com.qayshp.GuliKitAccessoryRepro`, process 14767.
Physical registry 4295419281, generation 1, matched the validated `33fa:ff02` /
serial `115411` fingerprint. These values are not claimed to be model-unique.

The source contained **no explicit `device.destroy()` calls**, including its
failure/quit cleanup. It still issued no USB configuration, interface, bulk,
SCSI, reset, firmware, or controller-sector command. This scopes the absence of
commands to the app; internal macOS/framework USB traffic was not captured.

## Timeline

Unified-log times below are **2026-11-16, America/Los_Angeles**. The on-screen
log displays UTC, eight hours ahead. Callback source entry and UI delivery are
recorded separately.

| Local time | Evidence |
| --- | --- |
| 01:13:20.953–20.959 | Connect callback 1; one candidate, state ready, generation 1, physical registry present. Snapshot configuration-data length was 0. |
| 01:14:16.309–16.328 | Claim invoked once and passed; returned client registry ID matched; physical presence and identity checks passed. Trace `B33CC17D-3360-42DB-B562-A344D1AD804E`. |
| 01:14:22.281 | Close invoked once, AA close only. |
| 01:14:22.289 | Accessory close returned; no explicit destruction issued. |
| 01:14:22.290–22.292 | App-owned strong client reference dropped; old device weak reference cleared; close-only PASS and Reopen enabled. |
| 01:14:28.307 | Reopen invoked once, about six seconds after weak-reference clearance. |
| 01:14:28.315–28.316 | Reopen returned successfully with physical presence and matching registry ID; API PASS. Trace `22E472F2-79E9-474B-AABA-D18CD6A3D4D8`. |
| 01:14:28.320 | AccessoryAccess entered disconnect callback 2, about 4 ms after Reopen PASS. |
| 01:14:28.345 | UI processed the disconnect; measured callback-to-UI delay 24.3 ms; phase finished, same physical registry present. |
| 01:14:28.351–28.352 | Cleanup close returned `AAErrorDomain` code 4, accessory already released. Cleanup scope ended with no explicit destruction call. |
| 01:14:28.355–28.358 | Connect callback 3 restored the same physical registry; final state recoveryRequired, generation 3. All numbered actions remained disabled. |

Final outcome: **Close-only API sequence initially completed, followed by
logical ownership loss. This is not a stable pass.** Exactly one Claim, one
Close, and one Reopen action were invoked. There was no retry, extra reset,
storage command, or firmware operation. The app was left open in the stopped
recovery state.

## Interpretation and limits

- The symptom does not require the extra explicit `destroy()` used by the
  [original variant](accessoryaccess-repro-result-2026-11-15.md).
- The old device wrapper's weak reference had cleared roughly six seconds
  before Reopen. A still-retained app-owned old wrapper does not explain this
  instance. Weak-reference clearance does not measure all internal daemon,
  driver, or kernel cleanup.
- ARC/framework automatic destruction remains part of ordinary object
  lifetime; this is not a claim that no internal destruction occurred.
- The framework callback entered before the 24.3 ms UI-delivery delay. That
  delay cannot explain the callback itself as an app-generated disconnect.
- Cleanup's already-released error followed the disconnect; cleanup did not
  initiate that earlier notification.
- Two AA-only cleanup variants have now shown the ownership-loss pattern on
  the same Mac/controller. This is stronger evidence than the original single
  attempt, but not a measured repeatability rate or a confirmed Apple bug.
- UI automation, OS routing/policy, controller-specific behavior, and other
  lifecycle/framework interactions have not all been excluded. A manual run
  of this unchanged build is a useful future control, requiring separate
  authorization and a fresh session.

No Apple feedback report was created or submitted. No further hardware action
followed the failure.
