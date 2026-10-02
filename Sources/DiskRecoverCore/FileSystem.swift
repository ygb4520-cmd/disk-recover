import Foundation

public enum FSError: LocalizedError {
    case notRecognized(String)
    case corrupt(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .notRecognized(let m), .corrupt(let m), .unsupported(let m): return m
        }
    }
}

/// A byte window onto a partition inside a DiskSource.
public struct Volume {
    public let src: DiskSource
    public let offset: UInt64
    public let length: UInt64
    public init(src: DiskSource, offset: UInt64, length: UInt64) {
        self.src = src; self.offset = offset; self.length = Swift.min(length, src.size > offset ? src.size - offset : 0)
    }
    public init(src: DiskSource, startLBA: UInt64, sectors: UInt64) {
        self.init(src: src, offset: startLBA * UInt64(src.sectorSize), length: sectors * UInt64(src.sectorSize))
    }
    public func read(_ rel: UInt64, _ n: Int) throws -> [UInt8] {
        guard rel < length, n > 0 else { return [] }
        return try src.read(offset: offset + rel, length: Int(Swift.min(UInt64(n), length - rel)))
    }
    public func readTolerant(_ rel: UInt64, _ n: Int) -> (data: [UInt8], badBytes: Int) {
        guard rel < length, n > 0 else { return ([], 0) }
        return src.readTolerant(offset: offset + rel, length: Int(Swift.min(UInt64(n), length - rel)))
    }
}

public enum Health: String {
    case intact = "Intact"
    case good = "Likely recoverable"
    case damaged = "Partly overwritten"
    case empty = "Empty"
    case unsupported = "Not supported"
}

public struct FSEntry: Identifiable {
    public var id: Int
    public var parent: Int            // -1 = volume root
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modified: Date?
    public var isDeleted: Bool
    public var health: Health
    /// Filesystem-specific: FAT/exFAT first cluster or NTFS MFT record number.
    var first: UInt64 = 0
    var flags: UInt32 = 0
}

public final class FSIndex {
    public private(set) var entries: [FSEntry]
    public private(set) var children: [Int: [Int]] = [:]
    public var volumeLabel: String?
    public var warnings: [String] = []

    init(entries: [FSEntry]) {
        self.entries = entries
        rebuild()
    }
    func rebuild() {
        children = [:]
        for e in entries { children[e.parent, default: []].append(e.id) }
    }
    public subscript(id: Int) -> FSEntry { entries[id] }
    public func path(of id: Int) -> String {
        var parts: [String] = []
        var cur = id
        var guardCount = 0
        while cur >= 0, guardCount < 512 { parts.append(entries[cur].name); cur = entries[cur].parent; guardCount += 1 }
        return "/" + parts.reversed().joined(separator: "/")
    }
    public var deletedCount: Int { entries.reduce(0) { $0 + ($1.isDeleted && !$1.isDirectory ? 1 : 0) } }
    public var fileCount: Int { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) } }
}

public struct ExtractResult {
    public var bytes: UInt64 = 0
    public var warnings: [String] = []
}

public protocol FileSystemReader: AnyObject {
    var info: FSInfo { get }
    func scan(progress: @escaping (Double) -> Void) throws -> FSIndex
    /// Stream the content of a file to `sink` in order.
    func extract(_ e: FSEntry, sink: ([UInt8]) throws -> Void) throws -> ExtractResult
    /// Byte ranges (absolute positions in the disk source) the filesystem considers unallocated.
    func freeRanges() throws -> [Range<UInt64>]
}

public enum FileSystemFactory {
    /// Open a filesystem inside `volume`. If the primary boot sector is unreadable, the backup copy is tried.
    public static func open(volume: Volume, sectorSize: Int) throws -> FileSystemReader {
        var candidates: [[UInt8]] = []
        if let p = try? volume.read(0, 4096) { candidates.append(p) }
        // Backup boot sectors: FAT32 sector 6, exFAT sector 12, NTFS last sector.
        for off in [UInt64(6 * 512), UInt64(12 * 512)] { if let b = try? volume.read(off, 4096) { candidates.append(b) } }
        if volume.length >= 512, let n = try? volume.read(volume.length - 512, 512) { candidates.append(n) }
        for (i, boot) in candidates.enumerated() {
            guard let info = FilesystemDetector.detect(sector: boot, sectorSize: sectorSize) else { continue }
            let usedBackup = i != 0
            switch info.kind {
            case .fat12, .fat16, .fat32:
                if let r = try? FATReader(volume: volume, boot: boot, usedBackupBoot: usedBackup) { return r }
            case .exfat:
                if let r = try? ExFATReader(volume: volume, boot: boot, usedBackupBoot: usedBackup) { return r }
            case .ntfs:
                if let r = try? NTFSReader(volume: volume, boot: boot, usedBackupBoot: usedBackup) { return r }
            default:
                throw FSError.unsupported("\(info.displayName) is recognized, but browsing and undeleting files is only supported for FAT, exFAT and NTFS. Use Photo Recovery to carve files from this partition instead.")
            }
        }
        throw FSError.notRecognized("No supported filesystem (FAT, exFAT or NTFS) was found at the start of this partition.")
    }
}

// MARK: shared helpers

enum DOSTime {
    private static let calendar = Calendar(identifier: .gregorian)
    static func date(date d: UInt16, time t: UInt16) -> Date? {
        let year = 1980 + Int(d >> 9), month = Int((d >> 5) & 0xF), day = Int(d & 0x1F)
        let hour = Int(t >> 11), minute = Int((t >> 5) & 0x3F), second = Int(t & 0x1F) * 2
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }
}

/// Lazily-read table of little-endian integers (FAT32 / exFAT allocation tables).
final class PagedTable {
    private let vol: Volume
    private let base: UInt64
    private let entrySize: Int
    private let pageBytes = 1 << 16
    private var cache: [Int: [UInt8]] = [:]
    private var order: [Int] = []

    init(vol: Volume, base: UInt64, entrySize: Int) { self.vol = vol; self.base = base; self.entrySize = entrySize }

    func get(_ index: UInt64) -> UInt32 {
        let byteOff = index * UInt64(entrySize)
        let page = Int(byteOff / UInt64(pageBytes)), inPage = Int(byteOff % UInt64(pageBytes))
        if cache[page] == nil {
            cache[page] = vol.readTolerant(base + UInt64(page) * UInt64(pageBytes), pageBytes).data
            order.append(page)
            if order.count > 64 { cache[order.removeFirst()] = nil }
        }
        let p = cache[page]!
        return entrySize == 4 ? p.le32(inPage) : UInt32(p.le16(inPage))
    }
}

/// Merge sorted/unsorted byte ranges that touch.
func mergeRanges(_ r: [Range<UInt64>]) -> [Range<UInt64>] {
    var out: [Range<UInt64>] = []
    for x in r.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = out.last, last.upperBound >= x.lowerBound { out[out.count - 1] = last.lowerBound..<Swift.max(last.upperBound, x.upperBound) }
        else { out.append(x) }
    }
    return out
}
