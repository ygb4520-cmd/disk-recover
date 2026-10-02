import Foundation

public struct FoundPartition: Identifiable {
    public let id = UUID()
    public var startLBA: UInt64
    public var sectorCount: UInt64
    public var fs: FSInfo
    public var confidence: Int
    public var viaBackup: Bool          // primary boot sector is damaged; located through a backup copy
    public var note: String
    public var matchesCurrentTable = false
    public var selected = true
    public var endLBA: UInt64 { startLBA + sectorCount - 1 }
}

public enum SearchMode { case quick, deep }

/// Searches a disk for filesystems by their boot-sector / superblock signatures (the TestDisk approach),
/// including copies of those structures, so partitions whose first sector was wiped can still be found.
public final class PartitionSearcher {
    private let src: DiskSource
    private let mode: SearchMode
    private let fromLBA: UInt64
    private let toLBA: UInt64
    private let ss: Int
    private let windowBytes = 8192

    public init(source: DiskSource, mode: SearchMode, fromLBA: UInt64 = 0, toLBA: UInt64? = nil) {
        self.src = source
        self.mode = mode
        self.ss = source.sectorSize
        self.fromLBA = fromLBA
        self.toLBA = Swift.min(toLBA ?? source.sectorCount, source.sectorCount)
    }

    public func run(currentTable: [PartitionEntry] = [], progress: @escaping (Double, Int) -> Void) throws -> [FoundPartition] {
        var found: [UInt64: FoundPartition] = [:]
        func add(_ c: FoundPartition) {
            if let old = found[c.startLBA], old.confidence >= c.confidence { return }
            found[c.startLBA] = c
        }

        func scanRange(_ lo: UInt64, _ hi: UInt64, report: Bool) throws {
            let chunkSectors = (4 << 20) / ss
            var lba = lo
            let hi = Swift.min(hi, toLBA)
            while lba < hi {
                try Task.checkCancellation()
                let n = Int(Swift.min(UInt64(chunkSectors), hi - lba))
                let (buf, _) = src.readTolerant(offset: lba * UInt64(ss), length: n * ss + windowBytes)
                buf.withUnsafeBufferPointer { p in
                    for i in 0..<n {
                        let o = i * ss
                        if o + 512 > p.count { break }
                        if !Self.prefilter(p, o) { continue }
                        let w = Array(p[o..<Swift.min(p.count, o + windowBytes)])
                        for c in probe(window: w, lba: lba + UInt64(i)) { add(c) }
                    }
                }
                lba += UInt64(n)
                if report { progress(Double(lba - lo) / Double(Swift.max(1, hi - lo)), found.count) }
            }
        }

        switch mode {
        case .quick:
            // Pass 1: aligned positions only (cheap random reads).
            let cands = quickCandidates()
            for (i, lba) in cands.enumerated() {
                try Task.checkCancellation()
                if let w = try? src.read(offset: lba * UInt64(ss), length: windowBytes), w.count >= 512 {
                    for c in probe(window: w, lba: lba) { add(c) }
                }
                if i % 256 == 0 { progress(Double(i) / Double(Swift.max(1, cands.count)) * 0.9, found.count) }
            }
            // Pass 2: partitions usually follow one another, so scan every sector just before the first
            // partition and just after each partition already found, whatever alignment the tool that made it used.
            try scanRange(fromLBA, fromLBA + 4096, report: false)
            var done = Set<UInt64>()
            var again = true
            while again {
                again = false
                for f in found.values.sorted(by: { $0.startLBA < $1.startLBA }) where !done.contains(f.startLBA) {
                    done.insert(f.startLBA)
                    let before = found.count
                    try scanRange(f.endLBA + 1, f.endLBA + 1 + 4096, report: false)
                    if found.count != before { again = true }
                }
            }
        case .deep:
            try scanRange(fromLBA, toLBA, report: true)
        }
        progress(1, found.count)
        return finalize(Array(found.values), currentTable: currentTable)
    }

    // MARK: probing

    @inline(__always)
    private static func prefilter(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> Bool {
        if p[o + 510] == 0x55 && p[o + 511] == 0xAA { return true }
        if o + 1082 <= p.count, p[o + 1080] == 0x53 && p[o + 1081] == 0xEF { return true }
        if o + 1026 <= p.count, p[o + 1024] == 0x48 && (p[o + 1025] == 0x2B || p[o + 1025] == 0x58) { return true }
        if p[o + 32] == 0x4E && p[o + 33] == 0x58 && p[o + 34] == 0x53 && p[o + 35] == 0x42 { return true }
        if p[o + 3] == 0x45 && p[o + 4] == 0x58 && p[o + 5] == 0x46 { return true }
        return false
    }

    private func quickCandidates() -> [UInt64] {
        var set = Set<UInt64>()
        let last = toLBA
        let unit = UInt64(ss)
        // Common alignment: 1 MiB, 4 KiB-physical, and legacy cylinder boundaries (255 heads x 63 sectors).
        let mib = Swift.max(1, (1 << 20) / unit)
        var l = (fromLBA + mib - 1) / mib * mib
        while l < last { set.insert(l); l += mib }
        for base in [UInt64(0), 34, 40, 56, 63, 64, 128, 256, 1024] where base >= fromLBA && base < last { set.insert(base) }
        let cyl: UInt64 = 16065
        l = (fromLBA + cyl - 1) / cyl * cyl
        while l < last { set.insert(l); if l + 63 < last { set.insert(l + 63) }; l += cyl }
        // The backup NTFS boot sector sits in the last sector of its volume.
        if last > 0 { set.insert(last - 1) }
        return set.sorted()
    }

    /// Examine the bytes at one candidate sector and return every partition they imply.
    private func probe(window w: [UInt8], lba: UInt64) -> [FoundPartition] {
        guard let fs = FilesystemDetector.detect(sector: w, sectorSize: ss) else { return [] }
        let u = UInt64(ss)
        func make(_ start: UInt64, _ conf: Int, _ backup: Bool, _ note: String) -> FoundPartition? {
            guard fs.totalSectors > 0, start + fs.totalSectors <= src.sectorCount else { return nil }
            return FoundPartition(startLBA: start, sectorCount: fs.totalSectors, fs: fs, confidence: conf, viaBackup: backup, note: note)
        }
        func bytesAt(_ byteOffset: UInt64, _ n: Int) -> [UInt8] { (try? src.read(offset: byteOffset, length: n)) ?? [] }

        switch fs.kind {
        case .fat12, .fat16, .fat32:
            let bps = UInt64(fs.bytesPerSector), reserved = UInt64(w.le16(14)), media = w.u8(21)
            func tableOK(_ start: UInt64) -> Bool {
                let t = bytesAt(start * u + reserved * bps, 4)
                return t.count == 4 && t[0] == media && t[1] == 0xFF && t[2] == 0xFF
            }
            if tableOK(lba) {
                let conf = fs.kind == .fat32 ? 80 : 65
                return [make(lba, conf, false, "")].compactMap { $0 }
            }
            if fs.kind == .fat32 {
                let backupSector = UInt64(w.le16(50)) * bps / u
                if backupSector > 0, lba >= backupSector, tableOK(lba - backupSector) {
                    return [make(lba - backupSector, 70, true, "Boot sector is damaged; this partition was located from the FAT32 backup boot sector.")].compactMap { $0 }
                }
            }
            return []
        case .exfat:
            let bps = UInt64(fs.bytesPerSector), fatOffset = UInt64(w.le32(80))
            func tableOK(_ start: UInt64) -> Bool {
                let t = bytesAt(start * u + fatOffset * bps, 8)
                return t.count == 8 && t.le32(0) == 0xFFFFFFF8 && t.le32(4) == 0xFFFFFFFF
            }
            if tableOK(lba) { return [make(lba, 85, false, "")].compactMap { $0 } }
            let backupSectors = 12 * bps / u
            if lba >= backupSectors, tableOK(lba - backupSectors) {
                return [make(lba - backupSectors, 75, true, "Boot region is damaged; this partition was located from the exFAT backup boot region.")].compactMap { $0 }
            }
            return []
        case .ntfs:
            let mftCluster = w.le64(48), cs = UInt64(fs.clusterSize)
            func mftOK(_ start: UInt64) -> Bool { bytesAt(start * u + mftCluster * cs, 4) == Array("FILE".utf8) }
            if mftOK(lba) { return [make(lba, 90, false, "")].compactMap { $0 } }
            let bpbSectors = w.le64(40) * UInt64(fs.bytesPerSector) / u
            if lba >= bpbSectors, mftOK(lba - bpbSectors) {
                return [make(lba - bpbSectors, 80, true, "Boot sector is damaged; this partition was located from the NTFS backup boot sector at the end of the volume.")].compactMap { $0 }
            }
            return []
        case .ext:
            let group = UInt64(w.le16(1024 + 90))
            if group == 0 { return [make(lba, 85, false, "")].compactMap { $0 } }
            let bpg = UInt64(w.le32(1024 + 32)), firstData = UInt64(w.le32(1024 + 20)), bs = UInt64(fs.clusterSize)
            let sbByte = lba * u + 1024
            let back = (group * bpg + firstData) * bs
            guard sbByte >= back else { return [] }
            let start = (sbByte - back) / u
            return [make(start, 55, true, "Primary superblock not checked; located from a backup superblock in group \(group).")].compactMap { $0 }
        case .hfsPlus:
            // A real volume keeps an alternate volume header 1024 bytes before its end; stray "H+" hits don't.
            let altOffset = lba * u + fs.totalSectors * u - 1024
            let alt = bytesAt(altOffset, 2)
            let hasAlt = alt == [0x48, 0x2B] || alt == [0x48, 0x58]
            return [make(lba, hasAlt ? 80 : 35, false, hasAlt ? "" : "No alternate volume header found at the end of this volume.")].compactMap { $0 }
        case .apfs:
            let bs = fs.clusterSize
            guard w.count >= bs, Self.apfsChecksumOK(Array(w[0..<bs])) else { return [] }
            return [make(lba, 85, false, "")].compactMap { $0 }
        }
    }

    static func apfsChecksumOK(_ block: [UInt8]) -> Bool {
        guard block.count >= 16, block.count % 4 == 0 else { return false }
        var sum1: UInt64 = 0, sum2: UInt64 = 0
        let mod: UInt64 = 0xFFFFFFFF
        var i = 8
        while i < block.count {
            sum1 = (sum1 + UInt64(block.le32(i))) % mod
            sum2 = (sum2 + sum1) % mod
            i += 4
        }
        let c1 = mod - ((sum1 + sum2) % mod)
        let c2 = mod - ((sum1 + c1) % mod)
        return block.le64(0) == (c2 << 32 | c1)
    }

    // MARK: result cleanup

    private func finalize(_ list: [FoundPartition], currentTable: [PartitionEntry]) -> [FoundPartition] {
        var items = list.sorted { $0.startLBA < $1.startLBA }
        // APFS keeps checkpoint copies of its container superblock a few blocks into the container.
        items = items.filter { cand in
            guard cand.fs.kind == .apfs else { return true }
            return !items.contains { o in o.fs.kind == .apfs && o.startLBA < cand.startLBA && o.sectorCount == cand.sectorCount &&
                (cand.startLBA - o.startLBA) * UInt64(ss) < (64 << 20) }
        }
        // Weak hits that overlap a stronger one are noise (e.g. stray signatures inside a volume).
        items = items.filter { cand in
            guard cand.confidence < 60 else { return true }
            return !items.contains { o in o.confidence >= 60 && overlap(o, cand) }
        }
        for i in items.indices {
            items[i].matchesCurrentTable = currentTable.contains {
                $0.startLBA == items[i].startLBA && abs(Int64($0.sectorCount) - Int64(items[i].sectorCount)) <= 2048
            }
        }
        // Default selection: best confidence first, skipping anything that overlaps an already chosen partition.
        for i in items.indices { items[i].selected = false }
        let order = items.indices.sorted {
            if items[$0].matchesCurrentTable != items[$1].matchesCurrentTable { return items[$0].matchesCurrentTable }
            if items[$0].confidence != items[$1].confidence { return items[$0].confidence > items[$1].confidence }
            return items[$0].sectorCount > items[$1].sectorCount
        }
        var chosen: [Int] = []
        for i in order where !chosen.contains(where: { overlap(items[$0], items[i]) }) {
            items[i].selected = true; chosen.append(i)
        }
        return items
    }

    public func overlap(_ a: FoundPartition, _ b: FoundPartition) -> Bool {
        a.startLBA <= b.endLBA && b.startLBA <= a.endLBA
    }
}
