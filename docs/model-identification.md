# NS58 model identification: evidence and limits

The current implementation matches a **validated updater fingerprint**. It does
not implement a vendor-documented query that positively identifies NS58 among
all GuliKit models.

## Observed layers

| Layer | Captured value | What it establishes |
| --- | --- | --- |
| USB vendor/product | `33fa:ff02` | Matches the updater captured from this NS58. Cross-model uniqueness is not established. |
| USB manufacturer/product strings | `Gulikit` / `Gulikit` | Generic brand identity; neither string says NS58. |
| USB serial | `115411` | Matches the tested serial profile. Uniqueness per unit or model is not established. |
| Storage model/revision | `USB-Dongle` / `1.01` | Updater/storage-interface identity, not a literal controller model or installed operational firmware version. |
| Interface | Configuration 1, interface 3, class `08`, subclass `06`, protocol `50`, 64-byte bulk endpoints | Narrows the updater's transport profile; not independently proven model-unique. |
| Capacity and FAT12 baseline | 119 × 4096 bytes; exact validated BPB/FAT/root layout | Further compatibility checks against the captured updater. |
| Root volume label | `GuliKit 3.7` | Version-bearing label, not an NS58 model string. |
| Firmware filename and pinned SHA-256 | `NS58_Elves2_V3.7.bin` | Identifies the selected file, not the physical controller receiving it. |

Local capture provenance remains outside the public source repository:
`outputs/linux-firmware-capture-20260726-210727/udev-before.txt` and
`outputs/firmware-capture-20260726-123147/preflight.json` in the investigation
workspace. No additional USB/model-query commands were issued for this review.

## Vendor evidence

GuliKit's [Elves 2 firmware page](https://www.gulikit.com/newsinfo/1071651.html)
explicitly associates this firmware with **Elves 2 / NS58** and describes the
version-bearing updater drive name. It does not provide an updater USB-ID model
table or a read-only NS58 model-identification command.

The [official setup tool](https://setup.gulikit.com/?language=1) lists NS09T,
NS38, NS39, and NS59, but does not list NS58 at the time of this review. Its
model-specific capabilities are a research lead, not permission to assume its
query protocol works on NS58 or to send unknown commands to the updater.

## Current safety policy

- Keep the strict USB descriptor, serial-profile, interface, capacity,
  FAT-baseline, and firmware-hash gates. Do not broaden supported models.
- Display **validated updater profile matched**, not automatic NS58 detection.
- Require explicit confirmation of the controller's **physical NS58 / Elves 2
  model label**, excluding NS59 / Elves 2 Pro, before enabling Install.
- Clear that confirmation on attachment changes, release, failure, or an
  installation attempt. Revalidate the attachment generation and confirmation
  after the Install confirmation dialog.

Physical-label confirmation adds a practical human check; it is not
cryptographic model authentication. A reliable general-purpose model detector
would need additional evidence, such as cross-model descriptor captures or a
validated vendor read-only model query. Neither has been established here.
