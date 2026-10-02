# Disk Recover

A native macOS app (SwiftUI) that does what TestDisk and PhotoRec do, with a GUI: analyse a disk, find lost
partitions, rebuild the partition table, repair boot sectors, browse and undelete files, and carve files out of raw space.
No third-party code or dependencies.

## Building

```
scripts/make_app.sh          # universal release build -> build/DiskRecover.app (ad-hoc signed)
scripts/make_app.sh debug    # faster debug build
swift test                   # core unit tests
```

Requires macOS 14+ and Xcode 16+. Open `build/DiskRecover.app`, pick a disk in the sidebar (or drop a disk image on the window).

## What it does

| Tab | Capability |
|---|---|
| **Partitions** | Reads MBR (incl. extended/logical), GPT (primary + backup, CRC-checked), Apple Partition Map, and bare filesystems. Reports damage: missing primary/backup GPT, missing protective MBR, overlaps, partitions past the end of the disk. |
| **Find Lost Partitions** | *Quick* or *Deep* (every sector) search for FAT12/16/32, exFAT, NTFS, ext2/3/4, HFS+ and APFS. If a volume's first sector is destroyed it is located through the FAT32 / exFAT / NTFS backup boot sector or an ext backup superblock. Select the right set and **write a new MBR or GPT** (logical partitions supported for MBR). **Repair Boot Sector** restores the backup copy over a damaged one. |
| **Files** | Browse FAT, exFAT and NTFS volumes **including deleted files and folders**, with a recoverability verdict (checked against the FAT / exFAT bitmap / NTFS `$Bitmap`). Recover selection or all deleted files, keeping folder structure. Handles long names (incl. restoring them for deleted FAT entries), fragmented NTFS runlists, `$ATTRIBUTE_LIST`, sparse files, orphaned NTFS files (“[Lost files]”). |
| **Photo Recovery** | Signature carving (PhotoRec style) for 18 families / 30+ extensions: JPEG, PNG, GIF, BMP, TIFF/CR2, WebP/WAV/AVI, MP4/MOV/M4A/HEIC, MKV/WebM, MP3, Ogg, PDF, legacy Office (doc/xls/ppt), RTF, ZIP (docx/xlsx/pptx/odt/epub/jar/apk), 7z, RAR, SQLite, PE. File sizes come from each format's structure, not a guess. Scan a partition, the whole disk, or only a filesystem's **unallocated space**. |
| **Tools** | Create a disk image (bad sectors zero-filled and reported), sector hex viewer, list/restore the automatic backups. |

## Safety model

* Everything opens **read-only**. Writes happen only from *Write Partition Table*, *Repair Boot Sector* and *Restore Backup*, each behind an explicit confirmation.
* Before any write, the affected sectors are saved to `~/Library/Application Support/DiskRecover/Backups/*.drbackup` and can be restored from Tools.
* Writes to the startup disk are refused. Physical disks are unmounted before writing.
* Recovered files are never written over existing files (`name (2)`), and you're warned if the destination is on the disk being recovered.

### Administrator access

macOS only lets root read `/dev/rdiskN`. Instead of running the whole app as root, Disk Recover starts a helper (the same
binary with `--helper`) through the normal administrator-password dialog. The helper opens the device and passes the open
file descriptor back over a Unix socket (`SCM_RIGHTS`); it only accepts `/dev/(r)diskN[sM]`, only from the invoking user, is
read-only unless a separate write-enabled helper is authorised, and exits when the app disconnects. Disk images need no privileges.

## Limits (be aware)

* Browse/undelete: FAT, exFAT, NTFS only. HFS+, APFS and ext partitions are detected (and can be carved) but not browsed.
* Deleted FAT files are assumed contiguous (the FAT chain is gone). Fragmented deleted files come back partly wrong; the status column says when clusters were reused.
* NTFS-compressed and encrypted files are reported as unsupported. NTFS *deleted-file* recovery depends on the MFT record surviving.
* SSDs with TRIM, and anything overwritten, cannot be recovered by any tool. Don't write to a disk you're trying to recover from.
* Carving finds contiguous files; names and folders are not recoverable that way.
* Verified on real macOS-made FAT32, exFAT, HFS+, APFS, MBR and GPT images and on a synthetic NTFS image (`Tests/Fixtures/make_ntfs.py`).
  The raw-device path (administrator helper, writes to physical disks) can't be exercised automatically; try new things on an image or a spare drive first.

## Command line

`drcli` is a scriptable front end for the same core: `analyze`, `search [--deep] [--write mbr|gpt]`, `ls`, `recover`, `carve [--free]`, `repair-boot`, `image`, `hex`.
For physical disks run it with `sudo`.

## Debug driver

Setting `DISKRECOVER_DEBUG_SCRIPT` (see `DebugDriver.swift`) makes the app drive itself and save window snapshots; it is inert otherwise.
