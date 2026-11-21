# Base GuliKit ES owners: could you share a read-only updater-drive snapshot?

I built a [native macOS firmware updater](https://github.com/qayshp/gulikit-updater) for my two GuliKit Elves 2 controllers so I wouldn’t have to switch to a Windows or Linux computer just to update them. I’m trying to find out whether the **base GuliKit ES** uses the same updater-drive layout. A screenshot suggests the sizes match, but a small disk snapshot would let me check.

If you have the **ES, not the ES Pro or ES Max**, could you capture the first 64 KiB of its updater drive? **Please don’t download or copy any firmware, run an updater, or format or repair the drive.** This is a read-only capture, not a firmware test.

[macOS](#on-macos) · [Linux](#on-linux) · [Windows](#on-windows) · [What to share](#what-to-share)

When you have your measurements, [submit an ES updater-drive report](https://github.com/qayshp/gulikit-updater/issues/new?template=es-updater-snapshot.yml). A GitHub account is needed to submit.

## Enter update mode without flashing

Disconnect any other removable drives you can safely unplug. With the controller still disconnected, take the first disk listing in your OS section below. Then, with the controller off, connect it using a USB data cable. Hold **Setting** (the gear button), press **Home**, then release Setting. This is how [GuliKit documents entering update mode](https://www.gulikit.com/newsinfo/1076221.html). **Stop before the file-copy step** on that page. If your OS offers to initialize, format, or repair the disk, decline.

The capture steps open the controller drive only for reading; they save the image to your computer. An OS that mounts the drive automatically can still do its own filesystem bookkeeping. If you can disable removable-drive automount before connecting, that makes for a cleaner capture. Don’t change system-wide storage settings just for this.

## On macOS

1. Run `diskutil list external physical` in Terminal **before and after** [entering update mode](#enter-update-mode-without-flashing).
2. Find the **new, small external USB disk**. It may appear as `GuliKit` or `NO NAME`; don’t identify it by name alone. Note its whole-disk ID, such as `disk7`, and check it with `diskutil info /dev/diskN`. Replace `N` with the number you actually see. If you aren’t sure which disk is the controller, stop here.
3. Unmount it with `diskutil unmountDisk /dev/diskN`. **Don’t eject it or force the unmount.** If unmounting fails or the controller disconnects, stop. Otherwise, replace `N` below with the same number and run:

```sh
snapshot_dir=$(mktemp -d /tmp/gulikit-es.XXXXXX) &&
  sudo dd if=/dev/rdiskN bs=65536 count=1 > "$snapshot_dir/es-updater-first-64KiB.img" &&
  wc -c "$snapshot_dir/es-updater-first-64KiB.img"
```

The controller is the **input**. The output goes to a new temporary folder on your Mac, not onto the controller. The last line should show `65536` bytes and the file’s path. If it’s shorter or there’s an error, report the error without attaching a file.

## On Linux

1. Run the command below in a terminal **before and after** [entering update mode](#enter-update-mode-without-flashing). Look for the **one new, small USB disk**. The row should say `disk` under `TYPE` and `usb` under `TRAN`. Use the **whole disk** (for example, `/dev/sdb`), not a partition (for example, `/dev/sdb1`). If you can’t tell which disk is the controller, stop.

```sh
lsblk -b -o PATH,TYPE,TRAN,SIZE,LOG-SEC,FSTYPE,LABEL,MOUNTPOINTS
```

2. Check that `MOUNTPOINTS` is blank for the disk **and each partition shown under it**. If the desktop mounted the updater, unmount each of its volumes normally: run `sudo umount -- '/exact/mountpoint'` with the actual mount point from the listing. Don’t use force or eject. Run the listing again and stop if the updater’s identity changed, it’s still mounted, or unmounting failed.
3. Replace `/dev/sdX` below with the confirmed **whole-disk** path and run:

```sh
snapshot_dir=$(mktemp -d /tmp/gulikit-es.XXXXXX) &&
  sudo dd if=/dev/sdX bs=65536 count=1 iflag=fullblock > "$snapshot_dir/es-updater-first-64KiB.img" &&
  wc -c "$snapshot_dir/es-updater-first-64KiB.img"
```

The last line should show exactly `65536` bytes and a file path under `/tmp`. Don’t share the file if there was an error or the size differs. For reference: [Linux disk listing](https://man7.org/linux/man-pages/man8/lsblk.8.html) and [GNU dd](https://www.gnu.org/software/coreutils/manual/coreutils.html#dd-invocation).

## On Windows

Use the portable edition of [HxD from its developer’s download page](https://mh-nexus.de/en/downloads.php?product=HxD20). Extract it to a folder on your PC, **not the controller drive**. HxD needs administrator access to open a physical disk. If you’d rather not use it, the disk information alone still helps.

1. In PowerShell, run this [disk listing](https://learn.microsoft.com/en-us/powershell/module/storage/get-disk) **before and after** [entering update mode](#enter-update-mode-without-flashing). Identify the **one new, small USB disk** and note its number, name, and size. It must not be a boot or system disk.

```powershell
Get-Disk | Where-Object BusType -eq USB |
    Format-Table Number, FriendlyName, Size, LogicalSectorSize, IsBoot, IsSystem
```

2. Right-click HxD and choose **Run as administrator**. In HxD, choose **Tools → Open disk…** (called **Extras → Open disk…** in the [developer-hosted walkthrough](https://mh-nexus.de/en/hxd/StarManSaveSectors.htm)). Select the confirmed **physical disk**, not the logical drive letter. Match the name and size where shown; don’t rely on a disk number alone. **Keep Open as Readonly checked.** If you can’t positively identify the disk or HxD can’t open it read-only, stop. Don’t turn off read-only mode to get past an error.
3. With the read-only disk tab active, choose **Edit → Select block…** (`Ctrl+E`). Select **dec** (decimal), set **Start-offset** to `0` and **Length** to `65536`, and click **OK**. The inclusive end offset should be `65535`.
4. Press `Ctrl+C` to copy the selection, then `Ctrl+N` to create a new file. **Confirm the new Untitled tab is active** before pressing `Ctrl+V`. Use **File → Save As** to save **only the new file** as `es-updater-first-64KiB.img` in a folder on your PC. Don’t paste or save anything on the disk tab.
5. In File Explorer, right-click the saved file and check **Properties → Size** (not **Size on disk**). It should be **65,536 bytes**. If it isn’t, don’t share the file. Close the read-only disk tab.

**Without installing HxD:** If Explorer shows an updater drive letter, you can report its [volume information](https://learn.microsoft.com/en-us/powershell/module/storage/get-volume) alongside the disk information from step 1. Replace `E` with the confirmed letter, without the colon:

```powershell
Get-Volume -DriveLetter E |
    Format-List FileSystemLabel, FileSystem, Size, SizeRemaining
```

## When you’re done

Press the controller’s rear **OFF** button and unplug it.

## What to share

Use the [ES updater-drive report form](https://github.com/qayshp/gulikit-updater/issues/new?template=es-updater-snapshot.yml) to confirm the model from its physical label and enter your OS and any measurements you have. Submitting the form opens a **public GitHub issue**. Don’t include serial numbers, UUIDs, full disk listings, or other drives’ details.

If you collected the `.img`, select **Saved the 65,536-byte image locally** so a maintainer can follow up. Keep the file on your computer; **don’t attach it or post a download link**, since raw filesystem data can contain identifiers.

If you’d rather not take a raw snapshot, the drive name and its **total and free space** are still helpful. No need to flash anything just for this. Thanks!
