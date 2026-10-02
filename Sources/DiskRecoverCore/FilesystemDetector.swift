import Foundation

public enum FSKind: String, CaseIterable {
    case fat12 = "FAT12", fat16 = "FAT16", fat32 = "FAT32", exfat = "exFAT", ntfs = "NTFS"
    case ext = "ext2/3/4", hfsPlus = "HFS+", apfs = "APFS"
    public var supportsFileRecovery: Bool { [.fat12, .fat16, .fat32, .exfat, .ntfs].contains(self) }
}

public struct FSInfo: Hashable {
    public var kind: FSKind
    public var displayName: String          // e.g. "ext4"
    public var totalSectors: UInt64         // in units of the disk's logical sector
    public var label: String?
    public var clusterSize: Int
    public var bytesPerSector: Int          // the filesystem's own sector size
}

public enum FilesystemDetector {
    /// Identify a filesystem from the bytes found at the start of a candidate partition.
    /// `sector` must hold at least 2048 bytes (4096 to also detect APFS/HFS+ reliably); shorter buffers still work for the FAT/NTFS family.
    public static func detect(sector s: [UInt8], sectorSize: Int) -> FSInfo? {
        guard s.count >= 512 else { return nil }
        let ss = UInt64(sectorSize)
        if s.hasPrefix(Array("EXFAT   ".utf8), at: 3), let e = exfat(s, ss) { return e }
        if s.le16(510) == 0xAA55 {
            if s.hasPrefix(Array("NTFS    ".utf8), at: 3), let n = ntfs(s, ss) { return n }
            if let f = fat(s, ss) { return f }
        }
        if s.count >= 1024 + 62, s.le16(1024 + 56) == 0xEF53, let e = ext(s, ss) { return e }
        if s.count >= 1024 + 64, s.hasPrefix([0x48, 0x2B], at: 1024) || s.hasPrefix([0x48, 0x58], at: 1024), let h = hfsPlus(s, ss) { return h }
        if s.hasPrefix(Array("NXSB".utf8), at: 32), let a = apfs(s, ss) { return a }
        return nil
    }

    static func isPow2(_ v: Int) -> Bool { v > 0 && v & (v - 1) == 0 }

    static func fat(_ s: [UInt8], _ ss: UInt64) -> FSInfo? {
        guard s[0] == 0xEB || s[0] == 0xE9 else { return nil }
        let bps = Int(s.le16(11)), spc = Int(s.u8(13)), reserved = Int(s.le16(14)), nfats = Int(s.u8(16))
        let rootEntries = Int(s.le16(17))
        guard [512, 1024, 2048, 4096].contains(bps), isPow2(spc), spc <= 128, reserved > 0, (1...4).contains(nfats) else { return nil }
        guard s.u8(21) >= 0xF0 || s.u8(21) == 0x00 else { return nil }
        var total = UInt64(s.le16(19)); if total == 0 { total = UInt64(s.le32(32)) }
        guard total > 0 else { return nil }
        var fatSize = UInt64(s.le16(22)); let is32 = fatSize == 0
        if is32 { fatSize = UInt64(s.le32(36)) }
        guard fatSize > 0 else { return nil }
        if is32 { guard rootEntries == 0, s.le16(42) == 0 else { return nil } }
        else { guard rootEntries > 0, rootEntries * 32 % bps == 0 else { return nil } }
        let rootSectors = UInt64((rootEntries * 32 + bps - 1) / bps)
        let overhead = UInt64(reserved) + UInt64(nfats) * fatSize + rootSectors
        guard total > overhead else { return nil }
        let clusters = (total - overhead) / UInt64(spc)
        let kind: FSKind = clusters < 4085 ? .fat12 : clusters < 65525 ? .fat16 : .fat32
        if (kind == .fat32) != is32 { return nil }
        let label = is32 ? s.ascii(71, 11) : s.ascii(43, 11)
        let bytes = total * UInt64(bps)
        return FSInfo(kind: kind, displayName: kind.rawValue, totalSectors: bytes / ss, label: label == "NO NAME" ? nil : (label.isEmpty ? nil : label),
                      clusterSize: spc * bps, bytesPerSector: bps)
    }

    static func exfat(_ s: [UInt8], _ ss: UInt64) -> FSInfo? {
        let sectorShift = Int(s.u8(108)), clusterShift = Int(s.u8(109))
        guard (9...12).contains(sectorShift), clusterShift <= 25 else { return nil }
        guard s[11..<64].allSatisfy({ $0 == 0 }) else { return nil }
        let total = s.le64(72)
        guard total > 0 else { return nil }
        guard s.le16(510) == 0xAA55 || s.le16((1 << sectorShift) - 2) == 0xAA55 else { return nil }
        let bytes = total << UInt64(sectorShift)
        return FSInfo(kind: .exfat, displayName: "exFAT", totalSectors: bytes / ss, label: nil,
                      clusterSize: 1 << (sectorShift + clusterShift), bytesPerSector: 1 << sectorShift)
    }

    static func ntfs(_ s: [UInt8], _ ss: UInt64) -> FSInfo? {
        let bps = Int(s.le16(11)), spc = Int(s.u8(13))
        guard [512, 1024, 2048, 4096].contains(bps), isPow2(spc) || spc >= 0xF4 else { return nil }
        let total = s.le64(40)
        guard total > 0, s.le64(48) > 0, s.le64(56) > 0 else { return nil }
        let clusterSize = spc >= 0xF4 ? 1 << (256 - spc) : spc * bps
        // The boot-sector count excludes the backup boot sector stored in the volume's last sector.
        let bytes = (total + 1) * UInt64(bps)
        return FSInfo(kind: .ntfs, displayName: "NTFS", totalSectors: bytes / ss, label: nil, clusterSize: clusterSize, bytesPerSector: bps)
    }

    static func ext(_ s: [UInt8], _ ss: UInt64) -> FSInfo? {
        let o = 1024
        let logBlock = Int(s.le32(o + 24))
        guard logBlock <= 6 else { return nil }
        let blockSize = 1024 << logBlock
        var blocks = UInt64(s.le32(o + 4))
        let incompat = s.le32(o + 96)
        if incompat & 0x80 != 0 { blocks |= UInt64(s.le32(o + 0x150)) << 32 }
        guard blocks > 0, s.le32(o + 40) > 0 /* inodes per group */, s.le32(o + 32) > 0 /* blocks per group */ else { return nil }
        let compat = s.le32(o + 92)
        let name: String
        if incompat & 0x240 != 0 || s.le32(o + 100) & 0x1 != 0 || incompat & 0x80 != 0 { name = "ext4" }
        else if compat & 0x4 != 0 { name = "ext3" } else { name = "ext2" }
        let label = s.ascii(o + 120, 16)
        return FSInfo(kind: .ext, displayName: name, totalSectors: blocks * UInt64(blockSize) / ss, label: label.isEmpty ? nil : label,
                      clusterSize: blockSize, bytesPerSector: 512)
    }

    static func hfsPlus(_ s: [UInt8], _ ss: UInt64) -> FSInfo? {
        let o = 1024
        let blockSize = UInt64(s.be32(o + 40)), blocks = UInt64(s.be32(o + 44))
        guard blockSize >= 512, blockSize.nonzeroBitCount == 1, blocks > 0, s.be16(o + 2) == 4 || s.be16(o + 2) == 5 else { return nil }
        let isX = s.u8(o + 1) == 0x58
        return FSInfo(kind: .hfsPlus, displayName: isX ? "HFSX" : "HFS+", totalSectors: blockSize * blocks / ss, label: nil,
                      clusterSize: Int(blockSize), bytesPerSector: 512)
    }

    static func apfs(_ s: [UInt8], _ ss: UInt64) -> FSInfo? {
        let blockSize = UInt64(s.le32(36)), blocks = s.le64(40)
        guard blockSize >= 4096, blockSize <= 65536, blockSize.nonzeroBitCount == 1, blocks > 0 else { return nil }
        return FSInfo(kind: .apfs, displayName: "APFS", totalSectors: blockSize * blocks / ss, label: nil,
                      clusterSize: Int(blockSize), bytesPerSector: 512)
    }
}
