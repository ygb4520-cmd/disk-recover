import Foundation

public final class FATReader: FileSystemReader {
    public let info: FSInfo
    private let vol: Volume
    private let kind: FSKind
    private let bps: Int, spc: Int
    private let clusterSize: Int
    private let clusterCount: Int
    private let fatStart: UInt64, rootStart: UInt64, dataStart: UInt64
    private let rootSectors: Int
    private let rootCluster: UInt32
    private var smallFAT: [UInt8] = []
    private var pagedFAT: PagedTable?
    private let usedBackupBoot: Bool

    init(volume: Volume, boot b: [UInt8], usedBackupBoot: Bool) throws {
        guard let info = FilesystemDetector.fat(b, UInt64(volume.src.sectorSize)) else { throw FSError.notRecognized("Not a FAT volume.") }
        self.info = info
        self.vol = volume
        self.kind = info.kind
        self.usedBackupBoot = usedBackupBoot
        bps = Int(b.le16(11)); spc = Int(b.u8(13))
        clusterSize = bps * spc
        let reserved = Int(b.le16(14)), nfats = Int(b.u8(16)), rootEntries = Int(b.le16(17))
        var total = UInt64(b.le16(19)); if total == 0 { total = UInt64(b.le32(32)) }
        var fatSize = UInt64(b.le16(22)); let is32 = fatSize == 0
        if is32 { fatSize = UInt64(b.le32(36)) }
        rootSectors = (rootEntries * 32 + bps - 1) / bps
        fatStart = UInt64(reserved * bps)
        rootStart = UInt64(reserved + nfats * Int(fatSize)) * UInt64(bps)
        dataStart = rootStart + UInt64(rootSectors * bps)
        clusterCount = Int((total - UInt64(reserved + nfats * Int(fatSize) + rootSectors)) / UInt64(spc))
        rootCluster = is32 ? b.le32(44) : 0
        if kind == .fat32 {
            pagedFAT = PagedTable(vol: volume, base: fatStart, entrySize: 4)
        } else {
            smallFAT = try volume.read(fatStart, Int(fatSize) * bps)
        }
    }

    // MARK: FAT access

    private func next(_ c: UInt32) -> UInt32 {
        switch kind {
        case .fat12:
            let o = Int(c) + Int(c) / 2
            let v = smallFAT.le16(o)
            return UInt32(c & 1 == 0 ? v & 0xFFF : v >> 4)
        case .fat16: return UInt32(smallFAT.le16(Int(c) * 2))
        default: return pagedFAT!.get(UInt64(c)) & 0x0FFF_FFFF
        }
    }
    private var eocMin: UInt32 { kind == .fat12 ? 0xFF8 : kind == .fat16 ? 0xFFF8 : 0x0FFF_FFF8 }
    private var badMark: UInt32 { kind == .fat12 ? 0xFF7 : kind == .fat16 ? 0xFFF7 : 0x0FFF_FFF7 }
    private func validCluster(_ c: UInt32) -> Bool { c >= 2 && Int(c) < clusterCount + 2 }
    private func clusterOffset(_ c: UInt32) -> UInt64 { dataStart + UInt64(c - 2) * UInt64(clusterSize) }

    private func chain(from first: UInt32, limit: Int = Int.max) -> [UInt32] {
        var out: [UInt32] = []
        var c = first
        var seen = Set<UInt32>()
        while validCluster(c), out.count < limit, !seen.contains(c) {
            out.append(c); seen.insert(c)
            let n = next(c)
            if n >= eocMin || n == badMark || n == 0 { break }
            c = n
        }
        return out
    }

    // MARK: scan

    private struct Pending { var dirEntry: Int; var cluster: UInt32; var deleted: Bool }

    public func scan(progress: @escaping (Double) -> Void) throws -> FSIndex {
        var entries: [FSEntry] = []
        var label: String?
        var queue: [Pending] = []
        var visitedDirs = Set<UInt32>()
        var warnings: [String] = []
        if usedBackupBoot { warnings.append("The boot sector was damaged; the backup boot sector was used to read this volume.") }

        func parse(_ bytes: [UInt8], parent: Int, parentDeleted: Bool) {
            var lfn: [(chars: [UInt16], checksum: UInt8)] = []
            var i = 0
            while i + 32 <= bytes.count {
                defer { i += 32 }
                let b0 = bytes[i]
                if b0 == 0x00 { break }
                let attr = bytes[i + 11]
                if attr & 0x3F == 0x0F {
                    var chars: [UInt16] = []
                    for o in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] { chars.append(bytes.le16(i + o)) }
                    lfn.append((chars, bytes[i + 13]))
                    continue
                }
                defer { lfn.removeAll() }
                if attr & 0x08 != 0 && attr & 0x10 == 0 {
                    if label == nil { label = Array(bytes[i..<(i + 11)]).ascii(0, 11) }
                    continue
                }
                if bytes[i] == 0x2E && (bytes[i + 1] == 0x20 || bytes[i + 1] == 0x2E) { continue }   // "." and ".."
                let deleted = b0 == 0xE5
                let entryBytes = Array(bytes[i..<(i + 32)])
                func lfnChecksum(_ b: [UInt8]) -> UInt8 {
                    var sum: UInt8 = 0
                    for k in 0..<11 { sum = ((sum &>> 1) | (sum << 7)) &+ b[k] }
                    return sum
                }
                // Long names are tied to the short name by a checksum. A deleted entry has lost the first
                // byte of its short name, so try every possible value to see whether the checksum still fits.
                var lfnMatches = false
                var restoredFirst: UInt8?
                if !lfn.isEmpty, Set(lfn.map { $0.checksum }).count == 1 {
                    let want = lfn[0].checksum
                    if deleted {
                        var probe = Array(entryBytes[0..<11])
                        for cand in 0...255 {
                            probe[0] = UInt8(cand)
                            if lfnChecksum(probe) == want { lfnMatches = true; restoredFirst = UInt8(cand); break }
                        }
                    } else { lfnMatches = lfnChecksum(entryBytes) == want }
                }
                var name: String
                if lfnMatches {
                    var units: [UInt16] = []
                    for piece in lfn.reversed() { units += piece.chars }
                    if let end = units.firstIndex(where: { $0 == 0 || $0 == 0xFFFF }) { units = Array(units[..<end]) }
                    name = String(decoding: units, as: UTF16.self)
                } else {
                    var raw = Array(entryBytes[0..<11])
                    if raw[0] == 0x05 { raw[0] = 0xE5 }
                    let lowerBase = entryBytes[12] & 0x08 != 0, lowerExt = entryBytes[12] & 0x10 != 0
                    func text(_ r: [UInt8], lower: Bool) -> String {
                        let s = String(decoding: r.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                        return lower ? s.lowercased() : s
                    }
                    var base = text(Array(raw[0..<8]), lower: lowerBase)
                    if deleted { base = "_" + base.dropFirst() }
                    let ext = text(Array(raw[8..<11]), lower: lowerExt)
                    name = ext.isEmpty ? base : base + "." + ext
                }
                if name.isEmpty { continue }
                let isDir = attr & 0x10 != 0
                let hi = kind == .fat32 ? UInt32(entryBytes.le16(20)) : 0
                let first = hi << 16 | UInt32(entryBytes.le16(26))
                let size = UInt64(entryBytes.le32(28))
                var e = FSEntry(id: entries.count, parent: parent, name: name, isDirectory: isDir, size: isDir ? 0 : size,
                                modified: DOSTime.date(date: entryBytes.le16(24), time: entryBytes.le16(22)),
                                isDeleted: deleted || parentDeleted, health: .intact)
                e.first = UInt64(first)
                let isDeleted = e.isDeleted
                if isDeleted && !isDir { e.health = health(first: first, size: size) }
                if isDeleted && isDir { e.health = .good }
                entries.append(e)
                if isDir, validCluster(first), !visitedDirs.contains(first) {
                    visitedDirs.insert(first)
                    queue.append(Pending(dirEntry: e.id, cluster: first, deleted: isDeleted))
                }
            }
        }

        // Root directory
        if kind == .fat32 {
            visitedDirs.insert(rootCluster)
            let bytes = readDirectory(cluster: rootCluster, deleted: false)
            parse(bytes, parent: -1, parentDeleted: false)
        } else {
            let bytes = (try? vol.read(rootStart, rootSectors * bps)) ?? []
            parse(bytes, parent: -1, parentDeleted: false)
        }

        var processed = 0
        while !queue.isEmpty {
            try Task.checkCancellation()
            let p = queue.removeFirst()
            if p.deleted {
                // Only trust a deleted directory if its first cluster still starts with "." pointing at itself.
                guard let head = try? vol.read(clusterOffset(p.cluster), 64), head.count == 64,
                      head[0] == 0x2E, head[1] == 0x20,
                      (UInt32(head.le16(20)) << 16 | UInt32(head.le16(26))) & (kind == .fat32 ? 0xFFFFFFFF : 0xFFFF) == p.cluster & (kind == .fat32 ? 0xFFFFFFFF : 0xFFFF)
                else { continue }
            }
            let bytes = readDirectory(cluster: p.cluster, deleted: p.deleted)
            parse(bytes, parent: p.dirEntry, parentDeleted: p.deleted)
            processed += 1
            if processed % 64 == 0 { progress(Swift.min(0.95, Double(processed) / Double(processed + queue.count + 1))) }
        }
        progress(1)
        let idx = FSIndex(entries: entries)
        idx.volumeLabel = label ?? info.label
        idx.warnings = warnings
        return idx
    }

    private func readDirectory(cluster: UInt32, deleted: Bool) -> [UInt8] {
        var out: [UInt8] = []
        if deleted {
            // The FAT chain was released; assume the directory is contiguous and still free.
            var c = cluster
            for _ in 0..<64 {
                guard validCluster(c), let d = try? vol.read(clusterOffset(c), clusterSize) else { break }
                out += d
                if d.chunked32().contains(where: { $0 == 0 }) { break }
                c += 1
                if next(c) != 0 { break }
            }
            return out
        }
        for c in chain(from: cluster, limit: 1 << 20) {
            guard let d = try? vol.read(clusterOffset(c), clusterSize) else { break }
            out += d
            if out.count > 256 << 20 { break }
        }
        return out
    }

    private func health(first: UInt32, size: UInt64) -> Health {
        if size == 0 { return .empty }
        guard validCluster(first) else { return .damaged }
        let n = Int((size + UInt64(clusterSize) - 1) / UInt64(clusterSize))
        guard Int(first) + n - 1 < clusterCount + 2 else { return .damaged }
        for k in 0..<n where next(first + UInt32(k)) != 0 { return .damaged }
        return .good
    }

    // MARK: extract

    public func extract(_ e: FSEntry, sink: ([UInt8]) throws -> Void) throws -> ExtractResult {
        var result = ExtractResult()
        guard e.size > 0 else { return result }
        let first = UInt32(truncatingIfNeeded: e.first)
        guard validCluster(first) else { throw FSError.corrupt("The starting cluster is invalid.") }
        let needed = Int((e.size + UInt64(clusterSize) - 1) / UInt64(clusterSize))
        var clusters: [UInt32]
        if e.isDeleted {
            clusters = (0..<needed).map { first + UInt32($0) }
            if clusters.last.map({ Int($0) >= clusterCount + 2 }) == true { throw FSError.corrupt("The file would extend past the end of the volume.") }
            if e.health == .damaged { result.warnings.append("Some clusters have been reused by other files; the recovered content may be corrupt.") }
        } else {
            clusters = chain(from: first, limit: needed)
            if clusters.count < needed { result.warnings.append("The cluster chain is shorter than the file size; the file is truncated.") }
        }
        var remaining = e.size
        var i = 0
        while i < clusters.count, remaining > 0 {
            try Task.checkCancellation()
            // Read runs of consecutive clusters in one go.
            var j = i
            while j + 1 < clusters.count, clusters[j + 1] == clusters[j] + 1, (j - i + 1) * clusterSize < (1 << 20) { j += 1 }
            let want = Swift.min(UInt64((j - i + 1) * clusterSize), remaining)
            let (data, bad) = vol.readTolerant(clusterOffset(clusters[i]), Int(want))
            if bad > 0 { result.warnings.append("Some sectors could not be read and were replaced with zeros.") }
            try sink(data)
            result.bytes += UInt64(data.count)
            remaining -= UInt64(data.count)
            if data.count < Int(want) { break }
            i = j + 1
        }
        result.warnings = Array(Set(result.warnings))
        return result
    }

    public func freeRanges() throws -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        var runStart: Int? = nil
        let base = vol.offset
        for c in 2..<(clusterCount + 2) {
            if c % 65536 == 0 { try Task.checkCancellation() }
            let free = next(UInt32(c)) == 0
            if free, runStart == nil { runStart = c }
            if (!free || c == clusterCount + 1), let s = runStart {
                let e = free ? c + 1 : c
                out.append((base + dataStart + UInt64(s - 2) * UInt64(clusterSize))..<(base + dataStart + UInt64(e - 2) * UInt64(clusterSize)))
                runStart = nil
            }
        }
        return out
    }
}

extension Array where Element == UInt8 {
    /// First byte of each 32-byte directory entry.
    func chunked32() -> [UInt8] { stride(from: 0, to: count, by: 32).map { self[$0] } }
}
