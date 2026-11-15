# GuliKit Updater for macOS

Experimental native updater for the GuliKit Elves 2 **NS58**, using macOS 27's
AccessoryAccess framework to claim the USB device and IOUSBHost to send the
firmware through USB mass storage Bulk-Only Transport.

The initial target is the known NS58 V3.7 firmware. Firmware is supplied at
runtime and verified against its known SHA-256. No GuliKit firmware is included
in this repository. NS59 / Elves 2 Pro is not supported.

## Status

Implementation in progress. A successful physical update on macOS is **not yet
verified**. The earlier raw disk implementation failed to trigger the updater;
this experiment uses the new exclusive USB handoff API.

Apple requires AccessoryAccess callers to be normal apps that appear in the
Dock, signed with `com.apple.developer.accessory-access.usb`. The USB operation
therefore runs in a minimal native app. A companion CLI handles offline work.

## Provenance

The FAT12 update plan comes from the July 2026 controller investigation:
Linux successfully wrote the padded firmware at LBA 10 (13 x 4096 bytes), then
the FAT copies and root metadata at LBA 1 (3 x 4096 bytes). The controller
powered off after those transfers. This repository reuses that plan while
replacing the macOS transport.

Official firmware page: https://www.gulikit.com/newsinfo/1071651.html

This project is independent of GuliKit and is not endorsed by GuliKit or Apple.
