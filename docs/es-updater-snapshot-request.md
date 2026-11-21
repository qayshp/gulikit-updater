# Base GuliKit ES owners: could you share a read-only updater-drive snapshot?

I built a [native macOS firmware updater](https://github.com/qayshp/gulikit-updater) for my two GuliKit Elves 2 controllers so I wouldn’t have to switch to a Windows or Linux computer just to update them. I’m trying to find out whether the **base GuliKit ES** uses the same updater-drive layout. A screenshot suggests the sizes match, but a small disk snapshot would let me check.

If you have the **ES, not the ES Pro or ES Max**, could you capture the first 64 KiB of its updater drive? **Please don’t download or copy any firmware, run an updater, or format or repair the drive.** This is a read-only capture, not a firmware test.

## On macOS

1. Disconnect any other removable drives you can safely unplug. With the controller still disconnected, run `diskutil list external physical` in Terminal so you know what’s already there.
2. With the controller off, connect it using a USB data cable. Hold **Setting** (the gear button), press **Home**, then release Setting. This is how [GuliKit documents entering update mode](https://www.gulikit.com/newsinfo/1076221.html). **Stop before the file-copy step** on that page.
3. Run `diskutil list external physical` again. Find the **new, small external USB disk**. It may appear as `GuliKit` or `NO NAME`; don’t identify it by name alone. Note its whole-disk ID, such as `disk7`, and check it with `diskutil info /dev/diskN`. Replace `N` with the number you actually see. If you aren’t sure which disk is the controller, stop here.
4. Unmount it with `diskutil unmountDisk /dev/diskN`. **Don’t eject it or force the unmount.** If unmounting fails or the controller disconnects, stop. Otherwise, replace `N` below with the same number and run:

```sh
snapshot_dir=$(mktemp -d /tmp/gulikit-es.XXXXXX) &&
  sudo dd if=/dev/rdiskN bs=65536 count=1 > "$snapshot_dir/es-updater-first-64KiB.img" &&
  wc -c "$snapshot_dir/es-updater-first-64KiB.img"
```

The controller is the **input**. The output goes to a new temporary folder on your Mac, not onto the controller. The last line should show `65536` bytes and the file’s path. If it’s shorter or there’s an error, don’t upload it. When you’re done, press the controller’s rear **OFF** button and unplug it.

## What to share

Please reply with the **exact model on the controller’s label**, your OS, and the updater drive’s **displayed name, disk size in bytes, and logical block size** if available. If you collected the `.img`, **message me privately before sharing it**: raw filesystem data can contain identifiers. Please don’t post serial numbers, UUIDs, or full disk listings.

If you’re on Windows or would rather not run Terminal commands, the drive name and its **total and free space** are still helpful. No need to flash anything just for this. Thanks!
