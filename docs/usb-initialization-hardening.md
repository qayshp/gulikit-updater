# USB initialization and inspection hardening

This work is non-flashing. It does not repeat the successful V3.7 reinstall or
change its two firmware/metadata commands, payload lengths, LBA ordering, status
validation, or no-retry policy.

## Lifecycle corrections

- Releasing the controller invalidates the inspected session **before** closing
  its transport. A failed AccessoryAccess release cannot leave Install enabled
  on an already-closed transport.
- Attachment generations distinguish detach/re-attach from duplicate connect
  notifications, even when the USB registry ID stays the same. Inspection checks
  the generation after acquiring access and again after the worker returns.
  Install also checks the inspected generation after its confirmation dialog.
- Quit is deferred during inspection, release, and installation. The app does
  not intentionally abandon or destroy a pipe while its worker is transferring.
- A consumed firmware-write session no longer produces a misleading
  power-cycle message for a different, newly attached registry ID.
- Listener callbacks now use a FIFO main-queue hop instead of independent
  unstructured MainActor tasks. Source callback sequence/uptime and UI delivery
  delay are logged separately, along with the active operation and physical
  registry presence. A logical disconnect still invalidates readiness even if
  the physical registry entry remains present.

Six offline tests cover attachment-generation invalidation, same-ID reattachment,
duplicate notifications, independent devices, and unknown/repeated detaches.
The accessory-release failure and quit policy are also source-reviewed; they
are not claimed as fault-injected hardware tests.

## Capacity response diagnostics

READ CAPACITY still declares **eight** data bytes in its CBW and uses the same
CDB. Only its input receive buffer changes to **64 bytes**, the validated bulk
endpoint's packet size. This permits observing an unexpected packet rather than
losing it to an eight-byte receive overrun.

- Exactly eight bytes are capacity data; the app still requires the exact NS58
  geometry and then a valid status wrapper.
- A thirteen-byte `USBS` packet with the matching tag is reported as premature
  status, including status/residue. It is never accepted as capacity data.
- The final status wrapper must be exactly thirteen bytes with the expected
  signature/tag, zero residue, and successful status.
- Malformed, oversized, truncated, or mismatched responses fail closed and
  invalidate the transport. No reset, REQUEST SENSE, or command retry is
  automatically attempted.

Seventeen parser tests cover those cases, including signature-looking capacity
data, reserved status values, invalid residues, and a bounded 64-byte hex dump.
Only initialization replies are logged, never firmware payloads.

## Ownership diagnostics and rejected assumption

The transport records the selected interface's registry ID, pre-configuration
interface count, configuration/open elapsed time, and the actual pipe device
and endpoint addresses. Returned pipe identities must match the selected NS58.
Interface discovery is bounded to two seconds; an actual open error is not
retried.

After exclusive AccessoryAccess open, the transport now checks the selected
configuration descriptor. If configuration 1 is already selected, it avoids
redundant SET_CONFIGURATION; otherwise it selects configuration 1 with matching
suppressed. Interface/endpoint and device-identity checks apply in either case.
An exclusive interface-open failure still fails closed, without a seize, reset,
or retry fallback. This avoids unnecessary configuration churn, but its effect
on the observed ownership transition still needs hardware verification.

A preliminary test required an interface ID different from all pre-configuration
IDs. It failed before any SCSI storage command because no such interface appeared
within the bound. That requirement was removed: a new registry ID is not a
safe readiness criterion for this controller. The retained-ID observation is
diagnostic, not a reason to accept a mismatched pipe or failed inspection.

## Evidence boundaries

The earlier OUT timeout and IN overrun are different observed failures. A
premature status packet is one hypothesis for the overrun, not an established
cause without packet evidence. Lifecycle fixes address definite stale-state
bugs but do not by themselves prove the cause of either transfer failure.

Apple documents that non-timeout bulk errors halt the endpoint and that clearing
a halt resets its toggle and aborts pending I/O. The BOT specification additionally
defines protocol reset recovery; simply retrying a command after an overrun is
not treated as safe synchronization here.

Primary references:

- [Apple IOUSBHostPipe clearStall](https://developer.apple.com/documentation/iousbhost/iousbhostpipe/clearstall())
- [USB-IF Bulk-Only Transport specification, sections 5 and 6](https://www.usb.org/sites/default/files/usbmassbulk_10.pdf)

## Initial revised-receiver hardware checks

On November 15, 2026 (America/Los_Angeles), the `2ff5764` build was tested without
selecting firmware. Install stayed disabled throughout.

| Time | Result |
| --- | --- |
| 16:39:02.984 | Capacity IN returned exactly eight bytes: `00 00 00 76 00 00 10 00`. The next IN returned a thirteen-byte matching CSW, zero residue, status zero. The interface ID was retained across configuration. |
| 16:39:03.100 | Capacity and FAT12 baseline inspection passed, label `GuliKit 3.7`. |
| 16:39:25.750 | Accessory close completed; the app reported release to macOS. |
| 16:39:29.827 | A second claim again returned the correct eight-byte capacity and a successful thirteen-byte CSW. |
| 16:39:29.830 | A logical AccessoryAccess disconnect for the same registry ID arrived during the baseline worker. |
| 16:39:29.948 | The worker result was rejected by the attachment-generation guard. Readiness was not published. |
| 16:39:29.959 | After cleanup, AccessoryAccess reported the same registry ID attached again. |

This verifies one complete inspection with the revised receiver and a second
valid capacity transaction. It also exposes a release/reclaim ownership-event
failure rather than a capacity packet failure in this run. No oversized packet
or premature CSW was observed, so the earlier overrun's cause remains unknown.
No firmware/storage-write command was sent in either check.

## Ordered-callback and conditional-configuration hardware checks

The `e5255ef` build repeated the same non-flashing test:

| Time | Result |
| --- | --- |
| 16:52:28.643 | Configuration 1 was already selected; SET_CONFIGURATION was skipped. |
| 16:52:28.771 | Capacity/status and FAT12 baseline inspection passed, label `GuliKit 3.7`. |
| 16:52:41.997 | Release to macOS completed. |
| 16:52:45.468 | A second exclusive claim was granted; configuration was again skipped. Capacity and status were correct. |
| 16:52:45.473 | The framework itself emitted disconnect callback 2 for the same registry ID. |
| 16:52:45.476 | The callback reached the UI after 2.7 ms, during inspection; the physical registry entry still existed. |
| 16:52:45.590 | The attachment-generation guard rejected the completed baseline result. |
| 16:52:45.608 | Callback 3 was delivered as a reconnect after cleanup. |

For this failure, neither redundant configuration nor delayed/reordered UI
delivery is a necessary cause. The guard correctly prevents a logically
detached inspection from enabling installation. Keeping the physical registry
entry does not make the ownership notification safe to ignore.

## Released-object lifetime experiment

A subsequent diagnostic build tags device and interface wrappers with copied
UUID labels and a deallocation sentinel. The sentinel does not retain the
observed wrapper. This records object reuse/final release without logging
addresses or issuing USB commands.

Its Release path keeps controls disabled while awaiting accessory close and
then explicitly calls the old device's documented, idempotent `destroy()` from
a detached worker, not from a framework completion handler. The intended test
is whether completing that cleanup before another claim avoids the observed
logical ownership loss. A delayed destructor is a hypothesis, not established
behavior.

The first attempt at this build stopped before any storage command:
configuration failed with `0xe00002d8` (`kIOReturnNotReady`) at 17:03:38.715.
The actual wrapper was observed as `_AAIOUSBHostDevice`; no behavior is selected
using that private class name. A separate test using the public two-argument
configuration entry point named by AccessoryAccess documentation also returned
NotReady at 17:08:47.289. Runtime comparison found neither configuration selector
overridden relative to IOUSBHostDevice, so an overload-bypass explanation is
not supported by that evidence.

The alternate configuration overload was not kept: the code retains its prior
`matchInterfaces:NO` policy when configuration is needed, avoiding a separate
kernel-driver-matching change in the lifetime experiment.

The lifetime/release comparison has therefore not yet run. It needs a fresh
physical update-mode session with a passing initial inspection. No firmware
was selected and no storage-write command was issued during these tests.

The later UI-control attempt was blocked because the Mac was locked and manual
unlock was required. AccessoryAccess's SDK documents automatic logical detach
and restoration for console-session transitions such as fast user switching or
logout. This is a relevant environment variable, not proof that locking caused
the earlier release/reclaim failure. The app now logs public NSWorkspace
session-active/resigned notifications for correlation, without collecting user
identities or changing lock/sleep settings. Those notifications are not a
complete lock-state detector. The next comparison requires a stable, manually
unlocked console session.

The signed Debug build passed. With the local firmware and Linux-root fixtures,
39 tests passed and the pinned ZIP-fixture extraction test was skipped because
that archive fixture was not supplied. The subsequent focused run passed all
23 parser/attachment tests. These offline results do not establish repeatable
hardware handoff behavior.

## Fresh unlocked session and explicitly approved BOT reset diagnostic

The user confirmed a full physical power cycle, fresh update-mode attachment,
and a manually unlocked/active console. The saved `464d666` build was launched.
At 21:42:00.262 configuration 1 was already selected, and the validated interface
opened normally. The first READ CAPACITY CBW OUT then timed out with `0/31`
bytes and `0xe00002d6`, before capacity data or a release/reclaim comparison.
No console-session notification was observed during that attempt; absence of
these notifications is not a complete proof that no lock-state transition
occurred.

The user then explicitly approved **one** standard mass-storage transport reset
followed by inspection. A separate **Reset Transport & Inspect…** action was
implemented. Normal Connect & Inspect and the firmware-write path do not call it.

The fixed recovery plan follows USB-IF BOT sections 3.1 and 5.3.4:

1. Interface-class reset on endpoint zero: setup bytes `21 ff 00 00 03 00 00 00`.
2. Clear halt on the validated bulk IN pipe.
3. Clear halt on the validated bulk OUT pipe.

The reset reservation is one-shot and requires no prior SCSI command or write.
It is consumed before caller I/O, including when a later control operation fails.
An unsupported reset is not ignored. Any phase failure closes the transport,
stops before inspection, and has no retry/fallback. No USB device/port reset,
REQUEST SENSE, or firmware write was added. Eight new policy/request tests pass;
the complete offline run has 47 passing tests and one archive-fixture skip.

### Actual approved-action result

The signed diagnostic app was launched with no firmware selected. At
21:53:46.600 the reset action was requested. Exclusive claim succeeded, but
configuration failed with `kIOReturnNotReady` at 21:53:46.933, before the
validated interface/pipes or reset method were reached.

**No BOT reset request was sent. No clear-halt, SCSI inspection command, or
firmware/filesystem write followed. No retry occurred.** This is an interface
configuration precondition failure, not a hardware result for BOT reset recovery.
Whether explicit BOT initialization helps the earlier timeout is still unknown.
The release-teardown experiment also remains unexercised in this fresh session.

### User-authorized unlocked retry

The user reported that the laptop had locked around the prior attempt and
authorized one retry with it unlocked, followed, if needed, by a macOS-configured
handoff and one additional reset-and-inspect attempt. The existing signed app
instance was kept open; no rebuild, relaunch, or firmware selection occurred.

At 22:21:49.399 the unlocked retry was requested for accessory registry
4295408786. Exclusive claim succeeded at 22:21:49.426, but configuration again
returned `0xe00002d8` (`kIOReturnNotReady`) at 22:21:49.729. The device wrapper was
released, and the app reported the configuration failure at 22:21:49.730.
There was no class-reset START log, clear-halt operation, SCSI inspection, or
firmware write. No automatic retry followed.

This establishes recurrence while the user reported an unlocked console. It
does not exclude persistent USB state from an earlier lock, or establish the
cause of the configuration failure. BOT reset recovery remains untested.

### Host handoff did not enumerate storage

The user selected **Use with this Mac**, but no volume appeared, including in
Disk Utility's unmounted-device view. The app received an accessory disconnect
at 22:56:48.860 (delivered at 22:56:48.864). Read-only registry inspection found
the exact NS58 `33fa:ff02`, serial `115411`, under a new registry ID 4295410352.
Its descendants contained a composite-device service and a device user client,
but no USB interface, mass-storage/SCSI stack, or block-media node. `diskutil`
reported no external physical disk of the expected 487424-byte size.

Thus this was not merely a missing Finder mount. Neither the routing selection
nor the registry snapshot establishes why the storage interfaces were absent.
The second authorized reset-and-inspect attempt was not invoked. The next
requested setup step is a physical power cycle while the accessory remains
assigned to the Mac, with the updater process left running. No configuration,
mount, reset, or storage write was issued during these read-only checks.
