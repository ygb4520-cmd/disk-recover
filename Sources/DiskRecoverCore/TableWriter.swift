import Foundation

public struct SectorWrite {
    public var lba: UInt64
    public var bytes: [UInt8]
    public var sectors: Int { bytes.count / 512 }
}

public struct PlannedPartition: Identifiable {
    public let id = UUID()
    public var startLBA: UInt64
    public var sectorCount: UInt64
    public var mbrType: UInt8
    public var gptType: GUID
    public var gptUnique: GUID = .random()
    public var name: String = ""
    public var bootable = false
    public var endLBA: UInt64 { startLBA + sectorCount - 1 }

    /// Turn a search result into something writable, keeping type/name/GUID from an existing entry at the same start.
    public init(found f: FoundPartition, existing: [PartitionEntry] = []) {
        startLBA = f.startLBA
        sectorCount = f.sectorCount
        var mt: UInt8 = 0x07, gt = PartitionTypes.msBasicData
        switch f.fs.kind {
        case .fat12: mt = 0x01
        case .fat16: mt = f.endLBA < 16_450_560 ? 0x06 : 0x0E
        case .fat32: mt = f.endLBA < 16_450_560 ? 0x0B : 0x0C
        case .ntfs, .exfat: mt = 0x07
        case .ext: mt = 0x83; gt = PartitionTypes.linuxFS
        case .hfsPlus: mt = 0xAF; gt = PartitionTypes.appleHFS
        case .apfs: mt = 0xAF; gt = PartitionTypes.appleAPFS
        }
        if f.fs.kind == .fat32, let l = f.fs.label?.uppercased(), l == "EFI", f.sectorCount * 512 <= (2 << 30) {
            mt = 0xEF; gt = PartitionTypes.efiSystem
        }
        mbrType = mt; gptType = gt
        if let e = existing.first(where: { $0.startLBA == f.startLBA }) {
            if e.mbrType != 0 { mbrType = e.mbrType }
            if let g = e.gptType { gptType = g }
            if let u = e.gptUnique { gptUnique = u }
            name = e.name
            bootable = e.bootable
        }
    }
}

public enum TableWriter {
    public enum Scheme { case mbr, gpt }

    public static func recommendedScheme(analysis: TableAnalysis, partitions: [PlannedPartition], diskSectors: UInt64) -> Scheme {
        if analysis.scheme == .gpt { return .gpt }
        if partitions.contains(where: { $0.endLBA > 0xFFFF_FFFE }) || diskSectors > 0xFFFF_FFFF { return .gpt }
        if analysis.scheme == .mbr { return .mbr }
        return partitions.count > 4 ? .gpt : .mbr
    }

    // MARK: planning

    public static func plan(scheme: Scheme, partitions: [PlannedPartition], disk: DiskSource, existing: TableAnalysis) throws -> [SectorWrite] {
        let parts = partitions.sorted { $0.startLBA < $1.startLBA }
        guard !parts.isEmpty else { throw DiskError.invalid("Select at least one partition to write.") }
        for i in 1..<Swift.max(1, parts.count) where parts[i].startLBA <= parts[i - 1].endLBA {
            throw DiskError.invalid("The selected partitions overlap; choose a set that does not.")
        }
        for p in parts where p.endLBA >= disk.sectorCount {
            throw DiskError.invalid("A selected partition extends beyond the end of the disk.")
        }
        switch scheme {
        case .mbr: return try planMBR(parts, disk: disk, existing: existing)
        case .gpt: return try planGPT(parts, disk: disk, existing: existing)
        }
    }

    static func chs(_ lba: UInt64) -> [UInt8] {
        if lba >= 1024 * 255 * 63 { return [0xFE, 0xFF, 0xFF] }
        let c = lba / (255 * 63), h = (lba / 63) % 255, s = lba % 63 + 1
        return [UInt8(h), UInt8(s | ((c >> 2) & 0xC0)), UInt8(c & 0xFF)]
    }

    static func mbrEntry(type: UInt8, start: UInt64, count: UInt64, boot: Bool) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 16)
        e[0] = boot ? 0x80 : 0
        e.put(1, chs(start))
        e[4] = type
        e.put(5, chs(start + count - 1))
        e.put32le(8, UInt32(truncatingIfNeeded: start))
        e.put32le(12, UInt32(truncatingIfNeeded: count))
        return e
    }

    static func planMBR(_ parts: [PlannedPartition], disk: DiskSource, existing: TableAnalysis) throws -> [SectorWrite] {
        for p in parts where p.endLBA > 0xFFFF_FFFF {
            throw DiskError.invalid("MBR cannot describe a partition that ends beyond 2 TiB. Use GPT.")
        }
        var sector0 = [UInt8](repeating: 0, count: 512)
        if existing.mbrSignatureValid, !existing.hasProtectiveMBR, existing.mbrBootCode.count == 446 {
            sector0.put(0, existing.mbrBootCode)
        }
        sector0[510] = 0x55; sector0[511] = 0xAA
        var writes: [SectorWrite] = []
        let primaries: [PlannedPartition], logicals: [PlannedPartition]
        if parts.count <= 4 { primaries = parts; logicals = [] }
        else { primaries = Array(parts.prefix(3)); logicals = Array(parts.dropFirst(3)) }
        var slot = 0
        for p in primaries {
            sector0.put(446 + slot * 16, mbrEntry(type: p.mbrType, start: p.startLBA, count: p.sectorCount, boot: p.bootable)); slot += 1
        }
        if !logicals.isEmpty {
            let firstEBR = logicals[0].startLBA - 1
            if let lastPrimary = primaries.last, lastPrimary.endLBA >= firstEBR {
                throw DiskError.invalid("Not enough free space before the first logical partition for its extended boot record.")
            }
            let extEnd = logicals.last!.endLBA
            sector0.put(446 + slot * 16, mbrEntry(type: 0x0F, start: firstEBR, count: extEnd - firstEBR + 1, boot: false))
            for (i, p) in logicals.enumerated() {
                let ebrLBA = p.startLBA - 1
                let prevEnd = i == 0 ? (primaries.last?.endLBA ?? 0) : logicals[i - 1].endLBA
                if i > 0 && ebrLBA <= prevEnd { throw DiskError.invalid("There is no free sector before logical partition at \(p.startLBA) for its extended boot record.") }
                var ebr = [UInt8](repeating: 0, count: 512)
                ebr.put(446, mbrEntry(type: p.mbrType, start: ebrLBA + 1, count: p.sectorCount, boot: p.bootable))
                if i + 1 < logicals.count {
                    let next = logicals[i + 1]
                    let nextEBR = next.startLBA - 1
                    ebr.put(462, mbrEntry(type: 0x05, start: nextEBR, count: next.endLBA - nextEBR + 1, boot: false))
                    // Entry 2 addresses are relative to the start of the extended partition.
                    ebr.put32le(462 + 8, UInt32(nextEBR - firstEBR))
                }
                ebr.put32le(446 + 8, 1)   // logical partition begins right after its EBR (relative to the EBR)
                ebr[510] = 0x55; ebr[511] = 0xAA
                writes.append(SectorWrite(lba: ebrLBA, bytes: ebr))
            }
        }
        writes.append(SectorWrite(lba: 0, bytes: sector0))
        return writes
    }

    static func planGPT(_ parts: [PlannedPartition], disk: DiskSource, existing: TableAnalysis) throws -> [SectorWrite] {
        let ss = disk.sectorSize
        guard ss >= 512 else { throw DiskError.invalid("Unsupported sector size.") }
        let entryCount = 128, entrySize = 128
        let entriesBytes = entryCount * entrySize
        let entrySectors = UInt64((entriesBytes + ss - 1) / ss)
        let last = disk.sectorCount - 1
        let firstUsable = 2 + entrySectors, lastUsable = last - entrySectors - 1
        guard parts.count <= entryCount else { throw DiskError.invalid("GPT supports at most 128 partitions here.") }
        for p in parts where p.startLBA < firstUsable || p.endLBA > lastUsable {
            throw DiskError.invalid("The partition at sector \(p.startLBA) lies outside the area GPT can use (sectors \(firstUsable)–\(lastUsable)). Use MBR for this layout instead.")
        }
        var entries = [UInt8](repeating: 0, count: Int(entrySectors) * ss)
        for (i, p) in parts.enumerated() {
            let o = i * entrySize
            entries.put(o, p.gptType.bytes)
            entries.put(o + 16, p.gptUnique.bytes)
            entries.put64le(o + 32, p.startLBA)
            entries.put64le(o + 40, p.endLBA)
            let units = Array(p.name.utf16.prefix(36))
            for (j, u) in units.enumerated() { entries.put16le(o + 56 + j * 2, u) }
        }
        let entriesCRC = CRC32.checksum(Array(entries[0..<entriesBytes]))
        let diskGUID = existing.diskGUID ?? .random()

        func header(myLBA: UInt64, altLBA: UInt64, entriesLBA: UInt64) -> [UInt8] {
            var h = [UInt8](repeating: 0, count: ss)
            h.put(0, Array("EFI PART".utf8))
            h.put32le(8, 0x0001_0000)
            h.put32le(12, 92)
            h.put64le(24, myLBA)
            h.put64le(32, altLBA)
            h.put64le(40, firstUsable)
            h.put64le(48, lastUsable)
            h.put(56, diskGUID.bytes)
            h.put64le(72, entriesLBA)
            h.put32le(80, UInt32(entryCount))
            h.put32le(84, UInt32(entrySize))
            h.put32le(88, entriesCRC)
            h.put32le(16, CRC32.checksum(Array(h[0..<92])))
            return h
        }

        var protective = [UInt8](repeating: 0, count: ss)
        if existing.mbrSignatureValid, existing.hasProtectiveMBR || existing.scheme == .gpt, existing.mbrBootCode.count == 446 {
            protective.put(0, existing.mbrBootCode.map { $0 })
        }
        let pmCount = Swift.min(disk.sectorCount - 1, 0xFFFF_FFFF)
        for i in 446..<510 { protective[i] = 0 }
        var entry = [UInt8](repeating: 0, count: 16)
        entry[0] = 0; entry.put(1, [0x00, 0x02, 0x00]); entry[4] = 0xEE; entry.put(5, [0xFF, 0xFF, 0xFF])
        entry.put32le(8, 1); entry.put32le(12, UInt32(pmCount))
        protective.put(446, entry)
        protective[510] = 0x55; protective[511] = 0xAA

        return [
            SectorWrite(lba: last - entrySectors, bytes: entries),
            SectorWrite(lba: last, bytes: header(myLBA: last, altLBA: 1, entriesLBA: last - entrySectors)),
            SectorWrite(lba: 2, bytes: entries),
            SectorWrite(lba: 1, bytes: header(myLBA: 1, altLBA: last, entriesLBA: 2)),
            SectorWrite(lba: 0, bytes: protective),
        ]
    }
}

/// Backs up the sectors that are about to change, applies the writes, and can restore from the backup.
public enum SectorWriter {
    public static var backupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DiskRecover/Backups", isDirectory: true)
    }

    private struct BackupHeader: Codable {
        var disk: String
        var created: String
        var sectorSize: Int
        var reason: String
        var ranges: [Range]
        struct Range: Codable { var lba: UInt64; var sectors: Int }
    }

    /// Saves the current content of every sector in `writes`. Returns the backup file.
    public static func backup(_ writes: [SectorWrite], from disk: DiskSource, reason: String) throws -> URL {
        let ss = disk.sectorSize
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        var data = Data()
        var ranges: [BackupHeader.Range] = []
        for w in writes {
            let sectors = (w.bytes.count + ss - 1) / ss
            let old = try disk.readSectors(lba: w.lba, count: sectors)
            data.append(contentsOf: old)
            ranges.append(.init(lba: w.lba, sectors: sectors))
        }
        let iso = ISO8601DateFormatter().string(from: Date())
        let header = BackupHeader(disk: disk.displayName, created: iso, sectorSize: ss, reason: reason, ranges: ranges)
        var out = Data("DRBACKUP1\n".utf8)
        out.append(try JSONEncoder().encode(header))
        out.append(0x0A)
        out.append(data)
        let name = "\(disk.displayName)-\(iso.replacingOccurrences(of: ":", with: "-")).drbackup"
        let url = backupDirectory.appendingPathComponent(name)
        try out.write(to: url)
        return url
    }

    public static func apply(_ writes: [SectorWrite], to disk: DiskSource, reason: String) throws -> URL {
        guard disk.isWritable else { throw DiskError.readOnly }
        let url = try backup(writes, from: disk, reason: reason)
        for w in writes {
            var bytes = w.bytes
            let pad = (disk.sectorSize - bytes.count % disk.sectorSize) % disk.sectorSize
            if pad > 0 { bytes += [UInt8](repeating: 0, count: pad) }
            try disk.write(offset: w.lba * UInt64(disk.sectorSize), bytes: bytes)
        }
        disk.flush()
        return url
    }

    public static func restore(backup url: URL, to disk: DiskSource) throws {
        guard disk.isWritable else { throw DiskError.readOnly }
        let data = try Data(contentsOf: url)
        let magic = Data("DRBACKUP1\n".utf8)
        guard data.starts(with: magic), let nl = data[magic.count...].firstIndex(of: 0x0A) else { throw DiskError.invalid("Not a Disk Recover backup file.") }
        let header = try JSONDecoder().decode(BackupHeader.self, from: data[magic.count..<nl])
        guard header.sectorSize == disk.sectorSize else { throw DiskError.invalid("The backup was made on a disk with a different sector size.") }
        var pos = nl + 1
        for r in header.ranges {
            let n = r.sectors * header.sectorSize
            guard pos + n <= data.count else { throw DiskError.invalid("The backup file is truncated.") }
            try disk.write(offset: r.lba * UInt64(header.sectorSize), bytes: [UInt8](data[pos..<(pos + n)]))
            pos += n
        }
        disk.flush()
    }
}

public enum BootRepair {
    public struct Status {
        public var primaryOK: Bool
        public var backupOK: Bool
        public var supported: Bool
        public var summary: String
    }

    private static func region(_ f: FSInfo, ss: Int) -> (primary: Int, backup: UInt64, sectors: Int)? {
        let bps = UInt64(f.bytesPerSector), u = UInt64(ss)
        switch f.kind {
        case .fat32: return (0, 6 * bps / u, Swift.max(1, Int(3 * bps / u)))
        case .exfat: return (0, 12 * bps / u, Swift.max(1, Int(12 * bps / u)))
        case .ntfs: return (0, f.totalSectors - 1, 1)
        default: return nil
        }
    }

    public static func assess(_ src: DiskSource, start: UInt64, fs: FSInfo) -> Status {
        guard let r = region(fs, ss: src.sectorSize) else {
            return Status(primaryOK: true, backupOK: false, supported: false, summary: "Boot sector repair is available for FAT32, exFAT and NTFS.")
        }
        func ok(_ lba: UInt64) -> Bool {
            guard let w = try? src.read(offset: lba * UInt64(src.sectorSize), length: 4096),
                  let d = FilesystemDetector.detect(sector: w, sectorSize: src.sectorSize) else { return false }
            return d.kind == fs.kind && d.totalSectors == fs.totalSectors
        }
        let p = ok(start), b = ok(start + r.backup)
        let s: String
        switch (p, b) {
        case (true, true): s = "Both the boot sector and its backup are valid."
        case (false, true): s = "The boot sector is damaged, but the backup copy is valid. It can be restored."
        case (true, false): s = "The boot sector is valid; the backup copy is missing or damaged."
        default: s = "Neither the boot sector nor its backup is valid."
        }
        return Status(primaryOK: p, backupOK: b, supported: true, summary: s)
    }

    /// Sector writes that copy the backup boot region over the primary one (or the reverse).
    public static func plan(_ src: DiskSource, start: UInt64, fs: FSInfo, backupToPrimary: Bool) throws -> [SectorWrite] {
        guard let r = region(fs, ss: src.sectorSize) else { throw DiskError.invalid("Unsupported filesystem for boot sector repair.") }
        let from = backupToPrimary ? start + r.backup : start
        let to = backupToPrimary ? start : start + r.backup
        var data = try src.readSectors(lba: from, count: r.sectors)
        if fs.kind == .fat32, backupToPrimary {
            // The backup FSInfo sector holds free-space hints from format time; mark them "unknown" so the OS recomputes them.
            let o = fs.bytesPerSector
            data.put32le(o + 488, 0xFFFF_FFFF)
            data.put32le(o + 492, 0xFFFF_FFFF)
        }
        return [SectorWrite(lba: to, bytes: data)]
    }
}
