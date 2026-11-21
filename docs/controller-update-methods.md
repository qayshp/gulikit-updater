# Controller update methods and research candidates

GuliKit's official instructions, reviewed November 21, 2026, document a drive-copy
update for several models. This is a good reason to investigate a shared
transport, not to assume identical bootloaders. **Official release lookups and
download links do not enable connected-device inspection or installation.** The
only native write path remains the [tested Elves 2 NS58 V3.7
profile](hardware-validation-2026-11-15.md).

## What GuliKit documents

The button combinations below start from a powered-off controller. **Setting**
is the gear button; **APG** is the double-square button. Where GuliKit documents
a USB drive, its procedure is to extract the model's package, copy the matching
BIN to the drive root, and leave the cable connected until the device powers off
and the drive disappears. These are the vendor's methods, not steps validated
by this app on the additional models.

| Controller and component | Documented USB path | Documented version observation |
| --- | --- | --- |
| [Elves 2 (NS58), main](https://www.gulikit.com/newsinfo/1071651.html) | Connect the cable; hold **Setting** and press **Home**. Copy the BIN to the updater drive. | GuliKit associates the mounted drive with the installed version. This project independently read `GuliKit 3.7` from its FAT root-directory volume label. |
| [ES, ES Pro, and ES Max, controller firmware](https://www.gulikit.com/newsinfo/1076221.html) | Connect the USB data cable; hold **Setting** and press **Home**. Copy the matching BIN to the updater drive. The page also documents firmware updates via GuliKit's mobile app starting with V4.2. | The official page associates the drive display with the current firmware number, as on NS58. We have not verified where the ES bootloader stores it on disk. |
| [TT Pro (NS68) and TT Max (NS69), main MCU](https://www.gulikit.com/newsinfo/3137265.html) | Connect the USB data cable; hold **APG** and press **Home**. Copy the model-specific main BIN to `GuliKit`. | GuliKit describes a **file on the drive** as reporting the current version. Do not assume the NS58 volume-label parser works here. |
| [TT Pro (NS68) and TT Max (NS69), Bluetooth MCU](https://www.gulikit.com/newsinfo/3137265.html) | Connect the cable; hold **Setting** and press **Home**. Copy the shared Bluetooth BIN to `GuliKit BT`, not the main updater drive. | The Bluetooth instructions identify the drive but do not specify how to read the installed Bluetooth version from it. |
| [KK3 (NS37), Bluetooth](https://www.gulikit.com/newsinfo/998404.html) | Hold **Setting** while connecting the supplied USB data cable. Open GuliKit's update utility and confirm its update action. | The instructions do not describe a version-bearing volume or file. The [NS37 product page](https://www.gulikit.com/productinfo/1280223.html) links to this Bluetooth release; no separate NS37 main release was verified. |
| [KK2T (NS09T), main](https://www.gulikit.com/newsinfo/1050207.html) | Connect the cable; hold **APG** and press **A**. Copy the matching BIN to `GuliKit`. | GuliKit says the new version can be checked after a normal restart, but does not specify a version-bearing volume label or file in these instructions. |
| [KK2T (NS09T), Bluetooth](https://www.gulikit.com/newsinfo/998414.html) | Connect the cable; press **Setting + A** and use GuliKit's update utility. This is not the main firmware drive-copy procedure. | The instructions do not describe an installed-version file or drive label. |

The TT release article describes two separate USB updates and an over-the-air
alternative after the documented main and Bluetooth prerequisites (V7.5 and
V02). Its release heading identifies the published release, not an independent
version number for each chip; its USB instructions include example filenames
that need not match the current archive. The [PC05 Hyperlink 2
receiver](https://www.gulikit.com/newsinfo/1092663.html) mentioned in the TT and
ES Max instructions is a separate product and requires its own firmware.

## What is worth testing next

**Start with the ES family.** Its button sequence, drive-based copy, and
documented version display make it the closest match to NS58. **KK2T main** is
another disk-copy candidate, even though its button sequence differs. **TT
main** is also promising, but its documented version file and the separate
Bluetooth target need component-specific handling. The documented NS37 and
KK2T Bluetooth utilities are separate research paths, not evidence that those
components work with the disk-copy updater.

For each candidate, begin with a separately authorized, read-only session:

1. Confirm the exact model from the physical label and deliberately select the
   documented component's update mode. Record USB identity and interfaces,
   without sending firmware, reset, or vendor-specific commands.
2. If a storage interface is present, check its transport and capacity, then
   read only the filesystem metadata and documented version indicator. Do not
   let the host write to the updater volume. Compare those results to the
   [NS58 evidence](model-identification.md), including the USB profile, block
   geometry, and root-directory layout; preserve model and component distinctions.
3. Treat a generic `GuliKit` label or matching USB identifier as a hint, not an
   identity guarantee. Add read-only model support only when the model,
   component, and reported version can be kept distinct; keep all new write
   actions disabled. A later write path requires its own verified package and
   layout, a separately approved reference update, and device-side validation.
