import Foundation

public final class ExFATReader: FileSystemReader {
    public let info: FSInfo
    private let vol: Volume
    private let bps: Int
    private let clusterSize: Int
    private let clusterCount: Int
    private let fatStart: UInt64, heapStart: UInt64
    private let rootCluster: UInt32
    private let fat: PagedTable
    private let usedBackupBoot: Bool
    private var bitmap: [UInt8]?

    init(volume: Volume, boot b: [UInt8], usedBackupBoot: Bool) throws {
        guard let info = FilesystemDetector.exfat(b, UInt64(volume.src.sectorSize)) else { throw FSError.notRecognized("Not an exFAT volume.") }
        self.info = info
        self.vol = volume
        self.usedBackupBoot = usedBackupBoot
        bps = 1 << Int(b.u8(108))
        clusterSize = bps << Int(b.u8(109))
        clusterCount = Int(b.le32(92))
        fatStart = UInt64(b.le32(80)) * UInt64(bps)
        heapStart = UInt64(b.le32(88)) * UInt64(bps)
        rootCluster = b.le32(96)
        fat = PagedTable(vol: volume, base: fatStart, entrySize: 4)
        guard clusterCount > 0, rootCluster >= 2 else { throw FSError.corrupt("exFAT boot sector is inconsistent.") }
    }

    private func valid(_ c: UInt32) -> Bool { c >= 2 && Int(c) < clusterCount + 2 }
    private func offset(_ c: UInt32) -> UInt64 { heapStart + UInt64(c - 2) * UInt64(clusterSize) }

    private func fatChain(_ first: UInt32, limit: Int) -> [UInt32] {
        var out: [UInt32] = []
        var c = first
        var seen = Set<UInt32>()
        while valid(c), out.count < limit, !seen.contains(c) {
            out.append(c); seen.insert(c)
            let n = fat.get(UInt64(c))
            if n >= 0xFFFFFFF7 || n < 2 { break }
            c = n
        }
        return out
    }

    private func loadBitmap(cluster: UInt32, length: UInt64) {
        guard valid(cluster), length > 0, length < (1 << 30), let d = try? vol.read(offset(cluster), Int(length)) else { return }
        bitmap = d
    }
    private func isAllocated(_ c: UInt32) -> Bool {
        guard let bm = bitmap else { return false }
        let i = Int(c - 2)
        guard i / 8 < bm.count else { return false }
        return bm[i / 8] & (1 << UInt8(i % 8)) != 0
    }

    /// Clusters holding a file's data, in order.
    private func clusters(first: UInt32, size: UInt64, noFatChain: Bool, deleted: Bool) -> (list: [UInt32], chainOK: Bool) {
        let needed = Int((size + UInt64(clusterSize) - 1) / UInt64(clusterSize))
        if needed == 0 { return ([], true) }
        if !noFatChain {
            let c = fatChain(first, limit: needed)
            if c.count == needed { return (c, true) }
            if !deleted { return (c, false) }
        }
        guard valid(first), Int(first) + needed - 1 < clusterCount + 2 else { return ([], false) }
        return ((0..<needed).map { first + UInt32($0) }, noFatChain || deleted)
    }

    private struct Pending { var dir: Int; var first: UInt32; var size: UInt64; var noFatChain: Bool; var deleted: Bool }

    public func scan(progress: @escaping (Double) -> Void) throws -> FSIndex {
        var entries: [FSEntry] = []
        var label: String?
        var queue: [Pending] = []
        var visited = Set<UInt32>()
        var warnings: [String] = []
        if usedBackupBoot { warnings.append("The boot region was damaged; the backup boot region was used to read this volume.") }

        func parse(_ bytes: [UInt8], parent: Int, parentDeleted: Bool) {
            var i = 0
            while i + 32 <= bytes.count {
                let type = bytes[i]
                if type == 0 { break }
                switch type {
                case 0x83:
                    let n = Int(bytes[i + 1])
                    if label == nil { label = bytes.utf16le(i + 2, chars: Swift.min(n, 15)) }
                    i += 32
                case 0x81:
                    // Allocation bitmap: remember where it lives.
                    if bitmap == nil { loadBitmap(cluster: bytes.le32(i + 20), length: bytes.le64(i + 24)) }
                    i += 32
                case 0x85, 0x05:
                    let secondary = Int(bytes[i + 1])
                    let setEnd = i + 32 * (secondary + 1)
                    guard secondary >= 2, setEnd <= bytes.count else { i += 32; continue }
                    let attrs = bytes.le16(i + 4)
                    let mtime = bytes.le32(i + 12)
                    let s = i + 32
                    let stype = bytes[s]
                    guard stype == 0xC0 || stype == 0x40 else { i += 32; continue }
                    let flags = bytes[s + 1]
                    let nameLen = Int(bytes[s + 3])
                    let first = bytes.le32(s + 20)
                    let size = bytes.le64(s + 24)
                    var units: [UInt16] = []
                    var k = s + 32
                    while k < setEnd, units.count < nameLen {
                        let t = bytes[k]
                        if t == 0xC1 || t == 0x41 {
                            for u in 0..<15 where units.count < nameLen { units.append(bytes.le16(k + 2 + u * 2)) }
                        }
                        k += 32
                    }
                    let name = String(decoding: units, as: UTF16.self)
                    let isDir = attrs & 0x10 != 0
                    let deleted = type == 0x05 || parentDeleted
                    var e = FSEntry(id: entries.count, parent: parent, name: name.isEmpty ? "(unnamed)" : name, isDirectory: isDir,
                                    size: isDir ? 0 : size,
                                    modified: DOSTime.date(date: UInt16(mtime >> 16), time: UInt16(mtime & 0xFFFF)),
                                    isDeleted: deleted, health: .intact)
                    e.first = UInt64(first)
                    e.flags = flags & 2 != 0 ? 1 : 0
                    if deleted {
                        if isDir { e.health = .good }
                        else if size == 0 { e.health = .empty }
                        else {
                            let (list, ok) = clusters(first: first, size: size, noFatChain: flags & 2 != 0, deleted: true)
                            e.health = (!ok || list.isEmpty || list.contains(where: { isAllocated($0) })) ? .damaged : .good
                        }
                    }
                    entries.append(e)
                    if isDir, valid(first), !visited.contains(first) {
                        visited.insert(first)
                        queue.append(Pending(dir: e.id, first: first, size: size, noFatChain: flags & 2 != 0, deleted: deleted))
                    }
                    i = setEnd
                default:
                    i += 32
                }
            }
        }

        func readDir(_ p: Pending) -> [UInt8] {
            var out: [UInt8] = []
            let cap = 256 << 20
            if p.deleted || p.noFatChain {
                let n = p.size > 0 ? Int((p.size + UInt64(clusterSize) - 1) / UInt64(clusterSize)) : 1
                for k in 0..<Swift.min(n, 4096) {
                    guard valid(p.first + UInt32(k)), let d = try? vol.read(offset(p.first + UInt32(k)), clusterSize) else { break }
                    out += d
                    if out.count > cap { break }
                }
            } else {
                for c in fatChain(p.first, limit: 1 << 20) {
                    guard let d = try? vol.read(offset(c), clusterSize) else { break }
                    out += d
                    if out.count > cap { break }
                }
            }
            return out
        }

        // The bitmap entry lives in the root directory, so parse the root first.
        let root = Pending(dir: -1, first: rootCluster, size: 0, noFatChain: false, deleted: false)
        parse(readDir(root), parent: -1, parentDeleted: false)
        // Health of deleted entries found before the bitmap was located was computed without it; recompute.
        if bitmap != nil {
            for i in entries.indices where entries[i].isDeleted && !entries[i].isDirectory && entries[i].size > 0 {
                let (list, ok) = clusters(first: UInt32(truncatingIfNeeded: entries[i].first), size: entries[i].size, noFatChain: entries[i].flags & 1 != 0, deleted: true)
                entries[i].health = (!ok || list.isEmpty || list.contains(where: { isAllocated($0) })) ? .damaged : .good
            }
        } else {
            warnings.append("The allocation bitmap could not be read, so recoverability of deleted files is a guess.")
        }

        var processed = 0
        while !queue.isEmpty {
            try Task.checkCancellation()
            let p = queue.removeFirst()
            parse(readDir(p), parent: p.dir, parentDeleted: p.deleted)
            processed += 1
            if processed % 64 == 0 { progress(Swift.min(0.95, Double(processed) / Double(processed + queue.count + 1))) }
        }
        progress(1)
        let idx = FSIndex(entries: entries)
        idx.volumeLabel = label
        idx.warnings = warnings
        return idx
    }

    public func extract(_ e: FSEntry, sink: ([UInt8]) throws -> Void) throws -> ExtractResult {
        var result = ExtractResult()
        guard e.size > 0 else { return result }
        let first = UInt32(truncatingIfNeeded: e.first)
        let (list, ok) = clusters(first: first, size: e.size, noFatChain: e.flags & 1 != 0, deleted: e.isDeleted)
        guard !list.isEmpty else { throw FSError.corrupt("The file's clusters cannot be located.") }
        if !ok { result.warnings.append("The cluster chain is shorter than the file size; the file is truncated.") }
        if e.isDeleted, e.health == .damaged { result.warnings.append("Some clusters appear to have been reused; the recovered content may be corrupt.") }
        var remaining = e.size
        var i = 0
        while i < list.count, remaining > 0 {
            try Task.checkCancellation()
            var j = i
            while j + 1 < list.count, list[j + 1] == list[j] + 1, (j - i + 1) * clusterSize < (1 << 20) { j += 1 }
            let want = Swift.min(UInt64((j - i + 1) * clusterSize), remaining)
            let (data, bad) = vol.readTolerant(offset(list[i]), Int(want))
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
        if bitmap == nil {
            // Locate the bitmap by scanning the root directory.
            var queue = Pending(dir: -1, first: rootCluster, size: 0, noFatChain: false, deleted: false)
            queue.deleted = false
            var bytes: [UInt8] = []
            for c in fatChain(rootCluster, limit: 4096) { bytes += (try? vol.read(offset(c), clusterSize)) ?? [] }
            var i = 0
            while i + 32 <= bytes.count, bytes[i] != 0 {
                if bytes[i] == 0x81 { loadBitmap(cluster: bytes.le32(i + 20), length: bytes.le64(i + 24)); break }
                i += 32
            }
        }
        guard bitmap != nil else { throw FSError.corrupt("The exFAT allocation bitmap could not be read.") }
        var out: [Range<UInt64>] = []
        var runStart: Int? = nil
        for c in 2..<(clusterCount + 2) {
            if c % 65536 == 0 { try Task.checkCancellation() }
            let free = !isAllocated(UInt32(c))
            if free, runStart == nil { runStart = c }
            if (!free || c == clusterCount + 1), let s = runStart {
                let e = free ? c + 1 : c
                out.append((vol.offset + heapStart + UInt64(s - 2) * UInt64(clusterSize))..<(vol.offset + heapStart + UInt64(e - 2) * UInt64(clusterSize)))
                runStart = nil
            }
        }
        return out
    }
}
