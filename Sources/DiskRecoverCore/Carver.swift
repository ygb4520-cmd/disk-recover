import Foundation

public struct CarveOptions {
    public var families: Set<String>
    /// Absolute byte ranges of the disk to scan (a partition, the whole disk, or the free space of a filesystem).
    public var ranges: [Range<UInt64>]
    /// Candidate start positions are `rangeStart + k * alignment`.
    public var alignment: Int
    public var destination: URL
    public var keepPartial: Bool

    public init(families: Set<String>, ranges: [Range<UInt64>], alignment: Int = 512, destination: URL, keepPartial: Bool = true) {
        self.families = families; self.ranges = ranges; self.alignment = alignment; self.destination = destination; self.keepPartial = keepPartial
    }
}

public struct CarvedFile: Identifiable {
    public let id = UUID()
    public var offset: UInt64
    public var length: UInt64
    public var ext: String
    public var family: String
    public var url: URL
    public var partial: Bool
}

public struct CarveProgress {
    public var scannedBytes: UInt64 = 0
    public var totalBytes: UInt64 = 0
    public var filesFound = 0
    public var partialFiles = 0
    public var perFamily: [String: Int] = [:]
    public var currentOffset: UInt64 = 0
    public init() {}
    public var fraction: Double { totalBytes == 0 ? 1 : Double(scannedBytes) / Double(totalBytes) }
}

public final class Carver {
    private let src: DiskSource
    private let opts: CarveOptions
    private let sigs: [Signature]
    private var tableAt0: [[Int]] = Array(repeating: [], count: 256)
    private var tableAt4: [[Int]] = Array(repeating: [], count: 256)

    public init(source: DiskSource, options: CarveOptions) {
        self.src = source
        self.opts = options
        self.sigs = CarveFormats.all.filter { options.families.contains($0.family) }
        for (i, s) in sigs.enumerated() {
            if s.magicOffset == 0 { tableAt0[Int(s.magic[0])].append(i) }
            else { tableAt4[Int(s.magic[0])].append(i) }
        }
    }

    public func run(progress: @escaping (CarveProgress) -> Void, onFile: @escaping (CarvedFile) -> Void) throws -> CarveProgress {
        var p = CarveProgress()
        p.totalBytes = opts.ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        let fm = FileManager.default
        try fm.createDirectory(at: opts.destination, withIntermediateDirectories: true)
        var lastReport = Date.distantPast
        func report(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 { lastReport = now; progress(p) }
        }
        let align = UInt64(Swift.max(opts.alignment, src.sectorSize))
        let chunk = Int((4 << 20) / align * align)

        for range in opts.ranges {
            let end = Swift.min(range.upperBound, src.size)
            var pos = range.lowerBound
            while pos < end {
                try Task.checkCancellation()
                let want = Int(Swift.min(UInt64(chunk), end - pos))
                let (buf, _) = src.readTolerant(offset: pos, length: want + 64)
                p.currentOffset = pos
                var skipTo: UInt64? = nil
                buf.withUnsafeBufferPointer { b in
                    var i = 0
                    while i < want, i + 8 <= b.count {
                        let hit0 = tableAt0[Int(b[i])]
                        let hit4 = tableAt4[Int(b[i + 4])]
                        if !hit0.isEmpty || !hit4.isEmpty {
                            for si in hit0 + hit4 {
                                let s = sigs[si]
                                let mo = i + s.magicOffset
                                guard mo + s.magic.count <= b.count else { continue }
                                var ok = true
                                for k in 0..<s.magic.count where b[mo + k] != s.magic[k] { ok = false; break }
                                guard ok else { continue }
                                let start = pos + UInt64(i)
                                let reader = StreamReader(src: src, base: start, limit: end)
                                switch s.sizer(reader) {
                                case .exact(let len, let ext) where len >= s.minSize && len <= s.maxSize && start + len <= end + 0:
                                    if let f = save(start: start, length: len, sig: s, ext: ext ?? s.defaultExt, partial: false) {
                                        p.filesFound += 1; p.perFamily[s.family, default: 0] += 1
                                        onFile(f)
                                        skipTo = start + ((len + align - 1) / align) * align
                                    }
                                case .partial(let len, let ext) where opts.keepPartial && len >= s.minSize && len <= s.maxSize:
                                    if let f = save(start: start, length: Swift.min(len, end - start), sig: s, ext: ext ?? s.defaultExt, partial: true) {
                                        p.filesFound += 1; p.partialFiles += 1; p.perFamily[s.family, default: 0] += 1
                                        onFile(f)
                                    }
                                default: break
                                }
                                if skipTo != nil { break }
                            }
                        }
                        if skipTo != nil { break }
                        i += Int(align)
                    }
                }
                if let s = skipTo, s > pos {
                    p.scannedBytes += Swift.min(s, end) - pos
                    pos = s
                } else {
                    p.scannedBytes += UInt64(want)
                    pos += UInt64(want)
                }
                report()
            }
        }
        report(force: true)
        return p
    }

    private func save(start: UInt64, length: UInt64, sig: Signature, ext: String, partial: Bool) -> CarvedFile? {
        let dir = opts.destination.appendingPathComponent(ext, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(format: "f%010llu%@.%@", start / 512, partial ? "_partial" : "", ext)
        let url = Extractor.uniqueURL(in: dir, name: name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? h.close() }
        var off = start
        var left = length
        while left > 0 {
            let n = Int(Swift.min(left, 1 << 20))
            let d = src.readTolerant(offset: off, length: n).data
            if d.isEmpty { break }
            do { try h.write(contentsOf: d) } catch { try? FileManager.default.removeItem(at: url); return nil }
            off += UInt64(d.count); left -= UInt64(d.count)
        }
        return CarvedFile(offset: start, length: length, ext: ext, family: sig.family, url: url, partial: partial)
    }
}

public struct ImageResult {
    public init() {}
    public var bytesCopied: UInt64 = 0
    public var unreadableBytes: UInt64 = 0
    public var unreadableRanges: [Range<UInt64>] = []
}

public enum DiskImager {
    /// Copy `range` of the source into a flat image file. Unreadable sectors are zero-filled and listed in the result.
    public static func copy(from src: DiskSource, range: Range<UInt64>, to url: URL, progress: @escaping (Double) -> Void) throws -> ImageResult {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw DiskError.invalid("\(url.lastPathComponent) already exists. Choose a new name.") }
        guard fm.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { throw DiskError.invalid("Cannot create \(url.path).") }
        var result = ImageResult()
        do {
            defer { try? h.close() }
            var pos = range.lowerBound
            let total = Double(range.upperBound - range.lowerBound)
            let chunk = 1 << 20
            while pos < range.upperBound {
                try Task.checkCancellation()
                let n = Int(Swift.min(UInt64(chunk), range.upperBound - pos))
                let (d, bad) = src.readTolerant(offset: pos, length: n)
                if bad > 0 {
                    result.unreadableBytes += UInt64(bad)
                    result.unreadableRanges.append(pos..<(pos + UInt64(n)))
                }
                try h.write(contentsOf: d)
                pos += UInt64(n)
                result.bytesCopied += UInt64(d.count)
                progress(Double(pos - range.lowerBound) / Swift.max(1, total))
                if d.count < n { break }
            }
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return result
    }
}
