import Foundation

public enum PartitionScheme: String {
    case none = "None"
    case mbr = "MBR"
    case gpt = "GPT"
    case apm = "Apple Partition Map"
    case bareFilesystem = "No table (filesystem starts at sector 0)"
}

public struct PartitionEntry: Identifiable, Hashable {
    public let id = UUID()
    public var index: Int
    public var startLBA: UInt64
    public var sectorCount: UInt64
    public var mbrType: UInt8 = 0
    public var gptType: GUID? = nil
    public var gptUnique: GUID? = nil
    public var name: String = ""
    public var bootable = false
    public var isLogical = false
    public var isExtendedContainer = false
    public var apmType: String = ""

    public var endLBA: UInt64 { sectorCount == 0 ? startLBA : startLBA + sectorCount - 1 }
    public func byteSize(sectorSize: Int) -> UInt64 { sectorCount * UInt64(sectorSize) }

    public var typeDescription: String {
        if let g = gptType { return PartitionTypes.gptName(g) }
        if !apmType.isEmpty { return apmType }
        return PartitionTypes.mbrName(mbrType) + (isLogical ? " (logical)" : "")
    }
    public static func == (a: PartitionEntry, b: PartitionEntry) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public struct TableIssue: Identifiable {
    public enum Severity { case info, warning, error }
    public let id = UUID()
    public let severity: Severity
    public let message: String
}

public struct TableAnalysis {
    public var scheme: PartitionScheme = .none
    public var partitions: [PartitionEntry] = []
    public var issues: [TableIssue] = []
    public var diskGUID: GUID? = nil
    public var mbrSignatureValid = false
    public var hasProtectiveMBR = false
    public var primaryGPTValid = false
    public var backupGPTValid = false
    public var mbrBootCode: [UInt8] = []
    public var sectorSize = 512
    public var diskSectors: UInt64 = 0
}

public enum PartitionTypes {
    static let mbrNames: [UInt8: String] = [
        0x00: "Empty", 0x01: "FAT12", 0x04: "FAT16 <32M", 0x05: "Extended", 0x06: "FAT16", 0x07: "NTFS / exFAT / HPFS",
        0x0B: "FAT32", 0x0C: "FAT32 (LBA)", 0x0E: "FAT16 (LBA)", 0x0F: "Extended (LBA)", 0x11: "Hidden FAT12",
        0x14: "Hidden FAT16", 0x17: "Hidden NTFS", 0x1B: "Hidden FAT32", 0x1C: "Hidden FAT32 (LBA)",
        0x27: "Windows Recovery", 0x42: "Windows Dynamic", 0x82: "Linux swap", 0x83: "Linux", 0x85: "Linux extended",
        0x8E: "Linux LVM", 0xA5: "FreeBSD", 0xA6: "OpenBSD", 0xA8: "Apple UFS", 0xA9: "NetBSD", 0xAB: "Apple Boot",
        0xAF: "Apple HFS+/APFS", 0xEE: "GPT protective", 0xEF: "EFI System", 0xFD: "Linux RAID",
    ]
    public static func mbrName(_ t: UInt8) -> String { mbrNames[t] ?? String(format: "Type 0x%02X", t) }

    public static let efiSystem = GUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")!
    public static let msBasicData = GUID("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")!
    public static let appleAPFS = GUID("7C3457EF-0000-11AA-AA11-00306543ECAC")!
    public static let appleHFS = GUID("48465300-0000-11AA-AA11-00306543ECAC")!
    public static let linuxFS = GUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")!
    static let gptNames: [GUID: String] = [
        efiSystem: "EFI System", msBasicData: "Microsoft basic data", appleAPFS: "Apple APFS", appleHFS: "Apple HFS+",
        linuxFS: "Linux filesystem", GUID("0657FD6D-A4AB-43C4-84E5-0933C84B4F4F")!: "Linux swap",
        GUID("E3C9E316-0B5C-4DB8-817D-F92DF00215AE")!: "Microsoft reserved",
        GUID("DE94BBA4-06D1-4D40-A16A-BFD50179D6AC")!: "Windows recovery",
        GUID("52637672-7900-11AA-AA11-00306543ECAC")!: "Apple APFS recovery",
        GUID("426F6F74-0000-11AA-AA11-00306543ECAC")!: "Apple boot",
        GUID("55465300-0000-11AA-AA11-00306543ECAC")!: "Apple UFS",
        GUID("21686148-6449-6E6F-744E-656564454649")!: "BIOS boot",
        GUID("E6D6D379-F507-44C2-A23C-238F2A3DF928")!: "Linux LVM",
    ]
    public static func gptName(_ g: GUID) -> String { gptNames[g] ?? "GPT \(g.description.prefix(8))" }
}

public enum PartitionTableParser {
    /// Inspect LBA 0 / LBA 1 / the last LBA of a disk and describe what the partition table says.
    public static func analyze(_ src: DiskSource) -> TableAnalysis {
        var a = TableAnalysis()
        a.sectorSize = src.sectorSize
        a.diskSectors = src.sectorCount
        let ss = src.sectorSize
        guard let s0 = try? src.readSectors(lba: 0, count: 1), s0.count == ss else {
            a.issues.append(TableIssue(severity: .error, message: "Cannot read the first sector of the disk."))
            return a
        }
        a.mbrSignatureValid = s0.le16(510) == 0xAA55
        a.mbrBootCode = Array(s0[0..<Swift.min(446, s0.count)])

        // GPT first: it can exist with a damaged or missing protective MBR.
        let gpt = readGPT(src)
        a.primaryGPTValid = gpt.primary != nil
        a.backupGPTValid = gpt.backup != nil

        var mbrEntries: [PartitionEntry] = []
        if a.mbrSignatureValid { mbrEntries = parseMBREntries(s0) }
        a.hasProtectiveMBR = mbrEntries.contains { $0.mbrType == 0xEE }

        if let table = gpt.primary ?? gpt.backup {
            a.scheme = .gpt
            a.partitions = table.entries
            a.diskGUID = table.diskGUID
            if gpt.primary == nil {
                a.issues.append(TableIssue(severity: .error, message: "The primary GPT is missing or corrupt. The backup GPT at the end of the disk is intact and is being shown instead."))
            } else if gpt.backup == nil {
                a.issues.append(TableIssue(severity: .warning, message: "The backup GPT at the end of the disk is missing or corrupt."))
            } else if gpt.primary!.entriesCRC != gpt.backup!.entriesCRC {
                a.issues.append(TableIssue(severity: .warning, message: "The primary and backup GPT partition lists differ."))
            }
            if !a.hasProtectiveMBR {
                a.issues.append(TableIssue(severity: .warning, message: "The protective MBR is missing or invalid. Other operating systems may treat this disk as empty."))
            }
            return finishChecks(&a)
        }

        if a.hasProtectiveMBR {
            a.scheme = .gpt
            a.issues.append(TableIssue(severity: .error, message: "The MBR says this is a GPT disk, but no valid GPT header was found (primary and backup are both damaged)."))
            return a
        }

        if s0.hasPrefix([0x45, 0x52]), let apm = parseAPM(src) {   // "ER"
            a.scheme = .apm
            a.partitions = apm
            return finishChecks(&a)
        }

        if s0.isAllZero {
            a.scheme = .none
            a.issues.append(TableIssue(severity: .warning, message: "The first sector is empty — there is no partition table on this disk."))
            return a
        }

        if a.mbrSignatureValid {
            // A FAT/NTFS/exFAT volume with no partition table also ends in 55 AA.
            if let fs = FilesystemDetector.detect(sector: s0 + ((try? src.read(offset: UInt64(ss), length: 4096)) ?? []), sectorSize: ss),
               [.fat12, .fat16, .fat32, .exfat, .ntfs].contains(fs.kind) {
                a.scheme = .bareFilesystem
                var p = PartitionEntry(index: 1, startLBA: 0, sectorCount: fs.totalSectors)
                p.name = fs.label ?? ""
                a.partitions = [p]
                return a
            }
            a.scheme = .mbr
            var parts = mbrEntries.filter { $0.mbrType != 0 }
            let extended = parts.filter { [0x05, 0x0F, 0x85].contains($0.mbrType) }
            for ext in extended {
                parts += walkExtended(src, container: ext, issues: &a.issues)
            }
            parts = parts.enumerated().map { var p = $1; p.index = $0 + 1; return p }
            a.partitions = parts
            if parts.isEmpty {
                a.issues.append(TableIssue(severity: .warning, message: "The MBR is valid but contains no partitions."))
            }
            return finishChecks(&a)
        }

        a.scheme = .none
        a.issues.append(TableIssue(severity: .warning, message: "No valid partition table signature was found in the first sector."))
        return a
    }

    private static func finishChecks(_ a: inout TableAnalysis) -> TableAnalysis {
        let real = a.partitions.filter { !$0.isExtendedContainer }
        for p in real where p.endLBA >= a.diskSectors {
            a.issues.append(TableIssue(severity: .error, message: "Partition \(p.index) extends beyond the end of the disk."))
        }
        for i in 0..<real.count {
            for j in (i + 1)..<Swift.max(i + 1, real.count) where real[i].startLBA <= real[j].endLBA && real[j].startLBA <= real[i].endLBA {
                a.issues.append(TableIssue(severity: .error, message: "Partitions \(real[i].index) and \(real[j].index) overlap."))
            }
        }
        return a
    }

    // MARK: MBR

    static func parseMBREntries(_ s: [UInt8]) -> [PartitionEntry] {
        (0..<4).compactMap { i in
            let o = 446 + i * 16
            let type = s.u8(o + 4)
            let start = UInt64(s.le32(o + 8)), count = UInt64(s.le32(o + 12))
            if type == 0 && start == 0 && count == 0 { return nil }
            var p = PartitionEntry(index: i + 1, startLBA: start, sectorCount: count)
            p.mbrType = type
            p.bootable = s.u8(o) == 0x80
            p.isExtendedContainer = [0x05, 0x0F, 0x85].contains(type)
            return p
        }
    }

    static func walkExtended(_ src: DiskSource, container: PartitionEntry, issues: inout [TableIssue]) -> [PartitionEntry] {
        var out: [PartitionEntry] = []
        var ebr = container.startLBA
        var seen = Set<UInt64>()
        while out.count < 128 {
            if seen.contains(ebr) { issues.append(TableIssue(severity: .error, message: "The extended partition chain loops back on itself.")); break }
            seen.insert(ebr)
            guard let s = try? src.readSectors(lba: ebr, count: 1), s.le16(510) == 0xAA55 else {
                issues.append(TableIssue(severity: .warning, message: "Extended boot record at sector \(ebr) is unreadable or has no signature."))
                break
            }
            let e = parseMBREntries(s)
            for p in e where !p.isExtendedContainer && p.sectorCount > 0 {
                var l = p
                l.startLBA = ebr + p.startLBA
                l.isLogical = true
                out.append(l)
            }
            guard let next = e.first(where: { $0.isExtendedContainer }) else { break }
            ebr = container.startLBA + next.startLBA
        }
        return out
    }

    // MARK: GPT

    struct GPTTable { var entries: [PartitionEntry]; var diskGUID: GUID; var entriesCRC: UInt32 }

    static func readGPT(_ src: DiskSource) -> (primary: GPTTable?, backup: GPTTable?) {
        let primary = parseGPT(src, headerLBA: 1)
        let last = src.sectorCount > 0 ? src.sectorCount - 1 : 0
        var backup = parseGPT(src, headerLBA: last)
        if backup == nil, let p = primary, p.alt != last { backup = parseGPT(src, headerLBA: p.alt) }
        return (primary?.table, backup?.table)
    }

    private static func parseGPT(_ src: DiskSource, headerLBA: UInt64) -> (table: GPTTable, alt: UInt64)? {
        let ss = src.sectorSize
        guard headerLBA < src.sectorCount, let h = try? src.readSectors(lba: headerLBA, count: 1), h.count == ss,
              h.hasPrefix(Array("EFI PART".utf8)) else { return nil }
        let headerSize = Int(h.le32(12))
        guard headerSize >= 92, headerSize <= ss else { return nil }
        var hz = Array(h[0..<headerSize]); hz.put32le(16, 0)
        guard CRC32.checksum(hz) == h.le32(16) else { return nil }
        guard h.le64(24) == headerLBA else { return nil }
        let entriesLBA = h.le64(72), numEntries = Int(h.le32(80)), entrySize = Int(h.le32(84))
        guard entrySize >= 128, entrySize <= 4096, numEntries > 0, numEntries <= 1024 else { return nil }
        let bytes = numEntries * entrySize
        guard entriesLBA < src.sectorCount, let raw = try? src.read(offset: entriesLBA * UInt64(ss), length: bytes), raw.count == bytes else { return nil }
        guard CRC32.checksum(raw) == h.le32(88) else { return nil }
        var entries: [PartitionEntry] = []
        for i in 0..<numEntries {
            let o = i * entrySize
            let type = GUID(bytes: Array(raw[o..<(o + 16)]))
            if type.isZero { continue }
            let first = raw.le64(o + 32), lastLBA = raw.le64(o + 40)
            guard lastLBA >= first else { continue }
            var p = PartitionEntry(index: i + 1, startLBA: first, sectorCount: lastLBA - first + 1)
            p.gptType = type
            p.gptUnique = GUID(bytes: Array(raw[(o + 16)..<(o + 32)]))
            p.name = raw.utf16le(o + 56, chars: 36).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            p.bootable = raw.le64(o + 48) & 4 != 0
            entries.append(p)
        }
        let table = GPTTable(entries: entries, diskGUID: GUID(bytes: Array(h[56..<72])), entriesCRC: h.le32(88))
        return (table, h.le64(32))
    }

    // MARK: Apple Partition Map

    static func parseAPM(_ src: DiskSource) -> [PartitionEntry]? {
        guard let first = try? src.read(offset: 512, length: 512), first.hasPrefix([0x50, 0x4D]) else { return nil }
        let count = Int(first.be32(4))
        guard count > 0, count < 64 else { return nil }
        var out: [PartitionEntry] = []
        for i in 0..<count {
            guard let b = try? src.read(offset: UInt64(512 * (i + 1)), length: 512), b.hasPrefix([0x50, 0x4D]) else { break }
            let type = b.ascii(48, 32)
            if type == "Apple_partition_map" { continue }
            var p = PartitionEntry(index: i + 1, startLBA: UInt64(b.be32(8)) * 512 / UInt64(src.sectorSize),
                                   sectorCount: UInt64(b.be32(12)) * 512 / UInt64(src.sectorSize))
            p.name = b.ascii(16, 32)
            p.apmType = type
            out.append(p)
        }
        return out
    }
}
