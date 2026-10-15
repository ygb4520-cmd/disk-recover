#if os(Windows)
import Foundation

/// Windows build: a random-access view of a disk-image file (phase 1 — raw physical devices are not supported yet).
public final class DiskSource: @unchecked Sendable {
    public let path: String
    public let size: UInt64
    public let sectorSize: Int
    public let isDevice = false
    public let isWritable: Bool
    public var bsdName: String? { nil }
    public var displayName: String { (path as NSString).lastPathComponent }
    public var sectorCount: UInt64 { size / UInt64(sectorSize) }

    private let handle: FileHandle
    private let lock = NSLock()

    public init(path: String, writable: Bool = false, sectorSizeOverride: Int? = nil) throws {
        self.path = path
        self.isWritable = writable
        let h: FileHandle?
        if writable { h = FileHandle(forUpdatingAtPath: path) } else { h = FileHandle(forReadingAtPath: path) }
        guard let handle = h else { throw DiskError.openFailed(path: path, errno: ENOENT) }
        self.handle = handle
        do { self.size = try handle.seekToEnd() } catch { throw DiskError.openFailed(path: path, errno: EIO) }
        self.sectorSize = sectorSizeOverride ?? 512
    }

    deinit { try? handle.close() }

    public func read(offset: UInt64, length: Int) throws -> [UInt8] {
        guard length > 0, offset < size else { return [] }
        let take = Int(Swift.min(size - offset, UInt64(length)))
        lock.lock(); defer { lock.unlock() }
        do {
            try handle.seek(toOffset: offset)
            return [UInt8](try handle.read(upToCount: take) ?? Data())
        } catch { throw DiskError.readFailed(offset: offset, errno: EIO) }
    }

    public func readTolerant(offset: UInt64, length: Int) -> (data: [UInt8], badBytes: Int) {
        if let d = try? read(offset: offset, length: length) { return (d, 0) }
        guard offset < size else { return ([], 0) }
        let end = Swift.min(size, offset + UInt64(length))
        var out = [UInt8](); var bad = 0
        var pos = offset
        let step = UInt64(sectorSize)
        while pos < end {
            let n = Int(Swift.min(step, end - pos))
            if let d = try? read(offset: pos, length: n), d.count == n { out += d }
            else { out += [UInt8](repeating: 0, count: n); bad += n }
            pos += UInt64(n)
        }
        return (out, bad)
    }

    public func readSectors(lba: UInt64, count: Int) throws -> [UInt8] {
        try read(offset: lba * UInt64(sectorSize), length: count * sectorSize)
    }

    public func write(offset: UInt64, bytes: [UInt8]) throws {
        guard isWritable else { throw DiskError.readOnly }
        guard offset + UInt64(bytes.count) <= size else { throw DiskError.invalid("Write beyond end of disk.") }
        lock.lock(); defer { lock.unlock() }
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(bytes))
        } catch { throw DiskError.writeFailed(offset: offset, errno: EIO) }
    }

    public func flush() { try? handle.synchronize() }
}
#endif
