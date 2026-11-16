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

The FIFO callback instrumentation and conditional-configuration change were
added after this sequence. Their build and focused tests pass, but their
hardware release/reclaim result is not yet established.

The signed Debug build passed. With the local firmware and Linux-root fixtures,
39 tests passed and the pinned ZIP-fixture extraction test was skipped because
that archive fixture was not supplied. The subsequent focused run passed all
23 parser/attachment tests. These offline results do not establish repeatable
hardware handoff behavior.
