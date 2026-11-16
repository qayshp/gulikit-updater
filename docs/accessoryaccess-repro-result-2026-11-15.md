# AA-only close/reopen reproduced delayed ownership loss

## Scope and environment

The user authorized one non-flashing **Claim → Close → Reopen** test, reported
keeping the Mac unlocked, and prepared a fresh rear-OFF/Setting+Home updater
session. The idle normal updater was quit normally and its process exit was
verified before the repro was opened. The user assigned Gulikit to
**AccessoryAccess Repro** in the macOS USB menu.

- macOS 27.2.1, build 26B131, arm64.
- Xcode 27.2, build 27B52.
- Source: `19393e34c9e897f4359fb024e16814f852b379d1`.
- Bundle: `com.qayshp.GuliKitAccessoryRepro`; signed sandboxed Debug build.
- Entitlements: AccessoryAccess USB, device USB, sandbox, development-signing
  metadata. No network/file-selection permission or temporary interface-client
  exception.
- Process: 12260. Captured physical registry: 4295413233, generation 1.
- Matched updater fingerprint: `33fa:ff02`, serial `115411`; not claimed to be
  unique per model/unit.
- Initial accessory configuration descriptor data length: 0. The app did not
  request a configuration; this observation is not a captured GET_CONFIGURATION
  response or an independent assertion about device-side configuration state.

The app contains no USB configuration, interface creation, bulk-pipe, SCSI,
BOT/reset, firmware-loading, or controller-sector I/O path. Each numbered
action was invoked once. No retry followed the failure.

## Observed timeline

Times below are from unified logging on **2026-11-15, America/Los_Angeles**.
The on-screen log uses UTC ISO timestamps; its corresponding date is November
16. Do not mix the two wall-clock renderings when quoting the sequence.

| Local time | Evidence |
| --- | --- |
| 23:50:58.848 | Listener registration PASS; no existing accessory, no automatic claim. |
| 23:51:41.071–41.077 | Connect callback 1; physical registry present; one candidate, generation 1, state ready. |
| 23:51:57.669 | Claim START, AA open only. |
| 23:51:57.749–57.750 | AA open returned; physical registry present, returned client ID matched 4295413233; Claim PASS. Trace `404F86AB-B7AC-441D-B180-BE1490D4C395`. |
| 23:52:04.243 | Close START for that trace. |
| 23:52:04.249–04.250 | Accessory close returned, explicit device destruction returned, Close PASS. |
| 23:52:08.658 | Reopen START, approximately 4.4 seconds after close completion. |
| 23:52:08.666–08.667 | AA open returned; physical presence and returned registry identity matched; Reopen API PASS. New trace `2A793863-F655-4475-BB1E-EF0FC3C15100`. |
| 23:52:08.760–08.761 | Disconnect callback 2 entered about 93 ms after Reopen PASS; UI delivery rounded to 0.0 ms; same physical registry remained present. State had been finished. |
| 23:52:08.763 | Cleanup close returned `AAErrorDomain` code 4: accessory already released. Cleanup device destruction returned. |
| 23:52:08.774–08.777 | Connect callback 3 for the same registry; UI delivery rounded to 0.0 ms; generation 3, state recoveryRequired, all numbered actions disabled. |

Final result: **the public API sequence initially completed, then logical
ownership was lost. This is not a stable close/reopen pass.** The app's
same-instance failure latch remained active after the logical reconnect. The
app was left open in that stopped state; no additional controller operation
was attempted.

## What this establishes

- The delayed logical ownership-loss symptom is reproducible with AA
  open → close/destroy → open alone on this controller/environment.
- The updater's configuration/interface/BOT/SCSI/firmware-writing code is not
  necessary to produce this instance of the symptom.
- The cleanup close error occurred after the disconnect callback. That cleanup
  error cannot explain the earlier callback as a cleanup-induced event.
- Physical USB registry presence and API-open success do not guarantee lasting
  AccessoryAccess ownership.
- The rounded 0.0 ms callback delivery measurement does not indicate a large
  delay in this app's main-queue hop. It does not measure internal framework
  queuing before callback entry.

## What remains unresolved

This single test does not establish repeatability across devices/boots or prove
an Apple framework defect. Framework routing, console/environment behavior,
entitlement interactions, and the minimal client's lifecycle remain variables
to investigate. There was no USB-bus capture or private framework-state trace.
No firmware compatibility, controller read/write behavior, or installation was
tested by this reproduction.

The source, steps, and timeline are suitable for a small Apple Feedback report,
but **no feedback was submitted** as part of this test.
