# NS58 native macOS reinstall validation — November 15, 2026

## Scope

One explicitly approved reinstall of the pinned NS58 V3.7 firmware, using the
signed native Debug app on macOS 27.2.1. App Sandbox remained enabled, with the
class-scoped `AppleUSBHostFrameworkInterfaceClient` temporary exception. No
sudo, installed driver, VM, or remote computer performed the transfer.

The controller was the previously validated `33fa:ff02`, serial `115411` unit.
The selected firmware was `NS58_Elves2_V3.7.bin`, 51,188 bytes, SHA-256:

```text
486c308e857b24adde6e7b623af67c8d0a74b6038f57ffc41ea7e2b94683e1eb
```

The runtime used the implementation recorded in commit `087add3`; the later
custom-error display refinement and documentation did not change transfer bytes.

## Observed sequence

Times below are America/Los_Angeles, from the app's unified logs.

| Time | Evidence |
| --- | --- |
| 11:37:22.238 | Pre-install inspection passed: 119 × 4096-byte blocks; validated clean FAT12 baseline; root label `GuliKit 3.7`. |
| 11:39:46.146 | One Install Once confirmation entered the install path. |
| 11:39:47.970 | Both BOT writes acknowledged: firmware at LBA 10, 53,248 bytes; metadata at LBA 1, 12,288 bytes. |
| 11:39:50.423 | Accessory detach notification received. |
| 11:39:50.558 | Original physical USB registry entry absent; app then closed/released its claim. |
| 11:40:01.401 | New update-mode USB session attached after the user restarted the controller. |
| 11:40:58.821 | Read-only post-inspection failed during READ CAPACITY data IN: endpoint `0x82`, reported `0/8` bytes, `0xe00002e8` (`kIOReturnOverrun`). |
| 11:46:33.754 | Fresh update-mode session attached after the user confirmed a normal start, power-off, and re-entry into update mode. |
| 11:46:53.897 | Read-only inspection passed again: expected 119 × 4096-byte capacity, clean FAT12 baseline, and root label `GuliKit 3.7`. No second install occurred. |

The user independently confirmed that the controller powered itself off
automatically, then was restarted with Setting + Home for the initial inspection.
After that inspection failed, the user confirmed a normal start, power-off,
and fresh update-mode session before the successful final inspection.

## Meaning and limits

For each write, acknowledgement requires a complete CBW and data transfer,
complete 13-byte CSW, matching `USBS` signature and tag, zero residue, and
successful command status. The physical registry disappearance happened about
2.6 seconds after both acknowledgements and before application cleanup, so it
was not caused by the app releasing its claim.

Together with the observed automatic power-off, this establishes that the
native app triggered the controller's normal firmware-update completion
behavior. Exactly one reinstall was attempted, with no automatic retry. The
post-inspections sent no firmware/storage-write commands. The successful final
inspection verifies that the expected version label and clean baseline were
present after a normal controller start and subsequent power cycle.

Game input and other normal controller functions were not tested. This
same-version reinstall does not independently prove which flash pages were
erased or rewritten, or validate upgrading from an older firmware version.
The successful transaction does not establish Release-build access, App Store
acceptance, other controller models/units, or reliable initialization on every
connection. Earlier timeouts and a data overrun remain relevant reliability
limitations even though the fresh final session passed.

The core experiment's goal is achieved: transfer the validated firmware and
trigger the controller's expected update completion behavior from a native
macOS app, with post-normal-restart version and baseline inspection. Further
work should focus on initialization reliability and distribution permissions,
not additional same-version reinstalls merely to repeat this result.
