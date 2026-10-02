import Foundation

public final class NTFSReader: FileSystemReader {
    public let info: FSInfo
    private let vol: Volume
    private let bps: Int
    private let clusterSize: Int
    private let recordSize: Int
    private let mftStart: UInt64
    private let totalClusters: UInt64
    private let usedBackupBoot: Bool
    private var mftRuns: [Run] = []
    private var mftSize: UInt64 = 0
    private var bitmap: [UInt8]?

    struct Run { var lcn: Int64; var length: UInt64 }      // lcn < 0 => sparse

    struct Attr {
        var type: UInt32
        var name: String
        var flags: UInt16
        var nonResident: Bool
        var content: [UInt8] = []          // resident
        var runs: [Run] = []               // non-resident
        var startVCN: UInt64 = 0
        var realSize: UInt64 = 0
    }

    struct Record {
        var number: UInt64
        var seq: UInt16
        var flags: UInt16
        var baseRef: UInt64
        var attrs: [Attr]
        var inUse: Bool { flags & 1 != 0 }
        var isDirectory: Bool { flags & 2 != 0 }
    }

    init(volume: Volume, boot b: [UInt8], usedBackupBoot: Bool) throws {
        guard let info = FilesystemDetector.ntfs(b, UInt64(volume.src.sectorSize)) else { throw FSError.notRecognized("Not an NTFS volume.") }
        self.info = info
        self.vol = volume
        self.usedBackupBoot = usedBackupBoot
        bps = Int(b.le16(11))
        clusterSize = info.clusterSize
        let cpr = Int8(bitPattern: b.u8(64))
        recordSize = cpr > 0 ? Int(cpr) * info.clusterSize : (1 << Int(-Int(cpr)))
        mftStart = b.le64(48)
        totalClusters = volume.length / UInt64(info.clusterSize)
        guard recordSize >= 256, recordSize <= 65536, recordSize % 512 == 0 else { throw FSError.corrupt("NTFS boot sector has an invalid record size.") }
        try loadMFTRuns()
    }

    // MARK: low-level parsing

    private static func parseRuns(_ b: [UInt8], from: Int, to: Int) -> [Run] {
        var runs: [Run] = []
        var o = from
        var lcn: Int64 = 0
        while o < to, b[o] != 0 {
            let lenSize = Int(b[o] & 0x0F), offSize = Int(b[o] >> 4)
            o += 1
            guard lenSize > 0, lenSize <= 8, offSize <= 8, o + lenSize + offSize <= to else { break }
            var length: UInt64 = 0
            for i in 0..<lenSize { length |= UInt64(b[o + i]) << UInt64(8 * i) }
            o += lenSize
            if offSize == 0 { runs.append(Run(lcn: -1, length: length)) }
            else {
                var delta: Int64 = 0
                for i in 0..<offSize { delta |= Int64(b[o + i]) << Int64(8 * i) }
                if b[o + offSize - 1] & 0x80 != 0 && offSize < 8 { delta -= Int64(1) << Int64(8 * offSize) }
                lcn += delta
                runs.append(Run(lcn: lcn, length: length))
            }
            o += offSize
        }
        return runs
    }

    private func parseRecord(_ raw: [UInt8], number: UInt64) -> Record? {
        guard raw.count == recordSize, raw.hasPrefix([0x46, 0x49, 0x4C, 0x45]) else { return nil }
        var b = raw
        let usaOff = Int(b.le16(4)), usaCount = Int(b.le16(6))
        guard usaCount >= 2, usaOff + usaCount * 2 <= recordSize, usaCount - 1 <= recordSize / 512 else { return nil }
        let usn = b.le16(usaOff)
        for i in 1..<usaCount {
            let p = i * 512 - 2
            guard b.le16(p) == usn else { return nil }          // torn write
            b[p] = b[usaOff + i * 2]; b[p + 1] = b[usaOff + i * 2 + 1]
        }
        let used = Swift.min(Int(b.le32(24)), recordSize)
        var attrs: [Attr] = []
        var o = Int(b.le16(20))
        while o + 16 <= used {
            let type = b.le32(o)
            if type == 0xFFFFFFFF { break }
            let len = Int(b.le32(o + 4))
            guard len >= 16, o + len <= recordSize else { break }
            let nonRes = b[o + 8] != 0
            let nameLen = Int(b[o + 9]), nameOff = Int(b.le16(o + 10))
            var a = Attr(type: type, name: nameLen > 0 ? b.utf16le(o + nameOff, chars: nameLen) : "", flags: b.le16(o + 12), nonResident: nonRes)
            if !nonRes {
                let cl = Int(b.le32(o + 16)), co = Int(b.le16(o + 20))
                if co + cl <= len, cl >= 0 { a.content = Array(b[(o + co)..<(o + co + cl)]) }
            } else {
                a.startVCN = b.le64(o + 16)
                a.realSize = b.le64(o + 48)
                let ro = Int(b.le16(o + 32))
                if ro < len { a.runs = Self.parseRuns(b, from: o + ro, to: o + len) }
            }
            attrs.append(a)
            o += len
        }
        return Record(number: number, seq: b.le16(16), flags: b.le16(22), baseRef: b.le64(32), attrs: attrs)
    }

    /// Read bytes from a non-resident stream described by `runs`.
    private func readStream(_ runs: [Run], offset: UInt64, length: Int, limit: UInt64? = nil, tolerant: Bool = true) -> [UInt8] {
        var want = UInt64(length)
        if let l = limit { if offset >= l { return [] }; want = Swift.min(want, l - offset) }
        var out: [UInt8] = []
        out.reserveCapacity(Int(want))
        var pos: UInt64 = 0
        let cs = UInt64(clusterSize)
        for r in runs {
            let runBytes = r.length * cs
            if offset + UInt64(out.count) >= pos + runBytes { pos += runBytes; continue }
            var cur = offset + UInt64(out.count)
            while cur < pos + runBytes, UInt64(out.count) < want {
                let inRun = cur - pos
                let n = Int(Swift.min(Swift.min(runBytes - inRun, want - UInt64(out.count)), 1 << 20))
                if r.lcn < 0 { out += [UInt8](repeating: 0, count: n) }
                else {
                    let (d, _) = vol.readTolerant(UInt64(r.lcn) * cs + inRun, n)
                    out += d
                    if d.count < n { out += [UInt8](repeating: 0, count: n - d.count) }
                }
                cur += UInt64(n)
            }
            pos += runBytes
            if UInt64(out.count) >= want { break }
        }
        return out
    }

    private func attributeData(_ a: Attr) -> [UInt8] {
        if !a.nonResident { return a.content }
        return readStream(a.runs, offset: 0, length: Int(Swift.min(a.realSize, 1 << 30)), limit: a.realSize)
    }

    private func readRecord(_ n: UInt64) -> Record? {
        let raw = readStream(mftRuns, offset: n * UInt64(recordSize), length: recordSize, limit: mftSize)
        return parseRecord(raw, number: n)
    }

    /// All attributes of a file, pulling in extension records referenced by $ATTRIBUTE_LIST.
    private func fullAttributes(_ rec: Record) -> [Attr] {
        var attrs = rec.attrs
        guard let list = rec.attrs.first(where: { $0.type == 0x20 }) else { return attrs }
        let data = attributeData(list)
        var seen: Set<UInt64> = [rec.number]
        var o = 0
        while o + 26 <= data.count {
            let len = Int(data.le16(o + 4))
            if len < 26 { break }
            let ref = data.le64(o + 16) & 0x0000_FFFF_FFFF_FFFF
            if !seen.contains(ref) {
                seen.insert(ref)
                if let ext = readRecord(ref), ext.baseRef & 0x0000_FFFF_FFFF_FFFF == rec.number {
                    attrs += ext.attrs.filter { $0.type != 0x20 }
                }
            }
            o += len
        }
        return attrs
    }

    private func dataAttributes(_ attrs: [Attr]) -> [Attr] {
        attrs.filter { $0.type == 0x80 && $0.name.isEmpty }.sorted { $0.startVCN < $1.startVCN }
    }

    private func loadMFTRuns() throws {
        let raw = try vol.read(mftStart * UInt64(clusterSize), recordSize)
        guard let rec = parseRecord(raw, number: 0) else {
            throw FSError.corrupt("The first $MFT record is unreadable. The volume's metadata is damaged.")
        }
        mftRuns = []
        let first = dataAttributes(rec.attrs)
        guard let head = first.first, head.nonResident else { throw FSError.corrupt("$MFT has no data stream.") }
        mftSize = head.realSize
        mftRuns = first.flatMap { $0.runs }
        if rec.attrs.contains(where: { $0.type == 0x20 }) {
            let all = dataAttributes(fullAttributes(rec))
            mftRuns = all.flatMap { $0.runs }
        }
    }

    private func loadBitmap() {
        guard bitmap == nil, let rec = readRecord(6), let a = dataAttributes(fullAttributes(rec)).first else { return }
        let all = dataAttributes(fullAttributes(rec))
        if a.nonResident {
            let runs = all.flatMap { $0.runs }
            bitmap = readStream(runs, offset: 0, length: Int(Swift.min(a.realSize, 1 << 30)), limit: a.realSize)
        } else { bitmap = a.content }
    }

    private func allocated(_ cluster: UInt64) -> Bool {
        guard let bm = bitmap else { return false }
        let i = Int(cluster / 8)
        return i < bm.count && bm[i] & (1 << UInt8(cluster % 8)) != 0
    }

    private static func ntTime(_ t: UInt64) -> Date? {
        guard t > 116_444_736_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(t / 10_000_000) - 11_644_473_600)
    }

    // MARK: scan

    public func scan(progress: @escaping (Double) -> Void) throws -> FSIndex {
        loadBitmap()
        var warnings: [String] = []
        if usedBackupBoot { warnings.append("The boot sector was damaged; the backup boot sector was used to read this volume.") }
        if bitmap == nil { warnings.append("The $Bitmap file could not be read, so recoverability of deleted files is a guess.") }

        let totalRecords = mftSize / UInt64(recordSize)
        struct Raw { var number: UInt64; var seq: UInt16; var inUse: Bool; var parentRef: UInt64 }
        var entries: [FSEntry] = []
        var raws: [Raw] = []
        let perChunk = Swift.max(1, (1 << 20) / recordSize)
        var n: UInt64 = 0
        while n < totalRecords {
            try Task.checkCancellation()
            let count = Int(Swift.min(UInt64(perChunk), totalRecords - n))
            let chunk = readStream(mftRuns, offset: n * UInt64(recordSize), length: count * recordSize, limit: mftSize)
            for i in 0..<count {
                let num = n + UInt64(i)
                let o = i * recordSize
                guard o + recordSize <= chunk.count, chunk[o] == 0x46, chunk[o + 1] == 0x49 else { continue }
                if num < 16 && num != 5 { continue }
                guard var rec = parseRecord(Array(chunk[o..<(o + recordSize)]), number: num), rec.baseRef == 0 else { continue }
                if num == 5 { continue }
                var attrs = rec.attrs
                if attrs.contains(where: { $0.type == 0x20 }), !attrs.contains(where: { $0.type == 0x80 && $0.name.isEmpty }) {
                    attrs = fullAttributes(rec); rec.attrs = attrs
                }
                // Best name: Win32/POSIX beats DOS 8.3.
                var best: (name: String, parent: UInt64, ns: UInt8, mtime: UInt64)?
                for a in attrs where a.type == 0x30 && !a.nonResident && a.content.count >= 66 {
                    let ns = a.content[65]
                    let nameLen = Int(a.content[64])
                    let name = a.content.utf16le(66, chars: nameLen)
                    let cand = (name: name, parent: a.content.le64(0), ns: ns, mtime: a.content.le64(16))
                    if best == nil || (best!.ns == 2 && ns != 2) { best = cand }
                }
                guard let nm = best, !nm.name.isEmpty else { continue }
                var mtime = nm.mtime
                if let si = attrs.first(where: { $0.type == 0x10 && !$0.nonResident }), si.content.count >= 16 { mtime = si.content.le64(8) }
                let isDir = rec.isDirectory
                var size: UInt64 = 0
                var health: Health = .intact
                var flags: UInt32 = 0
                if !isDir {
                    let ds = dataAttributes(attrs)
                    if let head = ds.first {
                        size = head.nonResident ? head.realSize : UInt64(head.content.count)
                        if head.flags & 0x0001 != 0 || head.flags & 0x4000 != 0 { flags |= 1; health = .unsupported }
                        if !rec.inUse && health != .unsupported {
                            if size == 0 { health = .empty }
                            else if !head.nonResident { health = .good }
                            else {
                                health = .good
                                outer: for r in ds.flatMap({ $0.runs }) where r.lcn >= 0 {
                                    for c in UInt64(r.lcn)..<(UInt64(r.lcn) + r.length) where allocated(c) { health = .damaged; break outer }
                                }
                            }
                        }
                    } else { health = .empty }
                } else if !rec.inUse { health = .good }
                var e = FSEntry(id: entries.count, parent: -1, name: nm.name, isDirectory: isDir, size: size,
                                modified: Self.ntTime(mtime), isDeleted: !rec.inUse, health: health)
                e.first = num
                e.flags = flags
                entries.append(e)
                raws.append(Raw(number: num, seq: rec.seq, inUse: rec.inUse, parentRef: nm.parent))
            }
            n += UInt64(count)
            progress(Double(n) / Double(Swift.max(1, totalRecords)))
        }

        // Resolve parents.
        var byNumber: [UInt64: Int] = [:]
        byNumber.reserveCapacity(entries.count)
        for (i, r) in raws.enumerated() { byNumber[r.number] = i }
        var orphanID: Int?
        var drop = Set<Int>()
        func orphanFolder() -> Int {
            if let o = orphanID { return o }
            var e = FSEntry(id: entries.count, parent: -1, name: "[Lost files]", isDirectory: true, size: 0, modified: nil, isDeleted: false, health: .intact)
            e.first = UInt64.max
            entries.append(e)
            orphanID = e.id
            return e.id
        }
        for i in 0..<raws.count {
            let r = raws[i]
            let pnum = r.parentRef & 0x0000_FFFF_FFFF_FFFF, pseq = UInt16(truncatingIfNeeded: r.parentRef >> 48)
            if pnum == 5 { entries[i].parent = -1; continue }
            if pnum == 11 || (pnum < 16 && pnum != 5) { drop.insert(i); continue }      // $Extend and other metadata
            if let pi = byNumber[pnum], entries[pi].isDirectory, pi != i {
                let actual = raws[pi].seq
                let ok = pseq == actual || (!raws[pi].inUse && pseq == actual &- 1)
                if ok { entries[i].parent = pi; continue }
            }
            entries[i].parent = orphanFolder()
        }
        if !drop.isEmpty {
            // Remove metadata children and re-number so ids stay equal to array indices.
            var remap: [Int: Int] = [:]
            var kept: [FSEntry] = []
            for e in entries where !drop.contains(e.id) { remap[e.id] = kept.count; var c = e; c.id = kept.count; kept.append(c) }
            for i in kept.indices where kept[i].parent >= 0 { kept[i].parent = remap[kept[i].parent] ?? -1 }
            entries = kept
        }
        // Parent cycles (corrupt data): detach anything whose chain never reaches the root.
        for i in entries.indices {
            var cur = entries[i].parent, steps = 0
            while cur >= 0, steps < 1024 { cur = entries[cur].parent; steps += 1 }
            if steps >= 1024 { entries[i].parent = -1 }
        }
        progress(1)
        let idx = FSIndex(entries: entries)
        idx.warnings = warnings
        return idx
    }

    // MARK: extract

    public func extract(_ e: FSEntry, sink: ([UInt8]) throws -> Void) throws -> ExtractResult {
        var result = ExtractResult()
        if e.flags & 1 != 0 { throw FSError.unsupported("Compressed or encrypted NTFS files cannot be recovered by this version.") }
        guard e.size > 0 else { return result }
        guard let rec = readRecord(e.first) else { throw FSError.corrupt("The file's MFT record is no longer readable.") }
        let ds = dataAttributes(fullAttributes(rec))
        guard let head = ds.first else { throw FSError.corrupt("The file has no data stream.") }
        if !head.nonResident {
            let d = Array(head.content.prefix(Int(e.size)))
            try sink(d); result.bytes = UInt64(d.count)
            return result
        }
        if e.isDeleted, e.health == .damaged { result.warnings.append("Some clusters have been reused by other files; the recovered content may be corrupt.") }
        let runs = ds.flatMap { $0.runs }
        var remaining = e.size
        let cs = UInt64(clusterSize)
        outer: for r in runs {
            var done: UInt64 = 0
            let runBytes = r.length * cs
            while done < runBytes, remaining > 0 {
                try Task.checkCancellation()
                let n = Int(Swift.min(Swift.min(runBytes - done, remaining), 1 << 20))
                if r.lcn < 0 { try sink([UInt8](repeating: 0, count: n)) }
                else {
                    let (d, bad) = vol.readTolerant(UInt64(r.lcn) * cs + done, n)
                    if bad > 0 { result.warnings.append("Some sectors could not be read and were replaced with zeros.") }
                    try sink(d)
                    if d.count < n { remaining -= UInt64(d.count); result.bytes += UInt64(d.count); break outer }
                }
                done += UInt64(n); remaining -= UInt64(n); result.bytes += UInt64(n)
            }
            if remaining == 0 { break }
        }
        if remaining > 0 { result.warnings.append("The data runs end before the recorded file size; the file is truncated.") }
        result.warnings = Array(Set(result.warnings))
        return result
    }

    public func freeRanges() throws -> [Range<UInt64>] {
        loadBitmap()
        guard let bm = bitmap else { throw FSError.corrupt("The $Bitmap file could not be read.") }
        var out: [Range<UInt64>] = []
        var runStart: UInt64? = nil
        let cs = UInt64(clusterSize)
        var c: UInt64 = 0
        while c < totalClusters {
            if c % (1 << 22) == 0 { try Task.checkCancellation() }
            if c % 8 == 0, Int(c / 8) < bm.count, bm[Int(c / 8)] == 0xFF, c + 8 <= totalClusters {
                if let s = runStart { out.append((vol.offset + s * cs)..<(vol.offset + c * cs)); runStart = nil }
                c += 8; continue
            }
            let free = !allocated(c)
            if free, runStart == nil { runStart = c }
            if !free, let s = runStart { out.append((vol.offset + s * cs)..<(vol.offset + c * cs)); runStart = nil }
            c += 1
        }
        if let s = runStart { out.append((vol.offset + s * cs)..<(vol.offset + totalClusters * cs)) }
        return out
    }
}
