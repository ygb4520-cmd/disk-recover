import Foundation
import CSupport

public enum DiskError: LocalizedError {
    case openFailed(path: String, errno: Int32)
    case readFailed(offset: UInt64, errno: Int32)
    case writeFailed(offset: UInt64, errno: Int32)
    case readOnly
    case misaligned
    case invalid(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let p, let e): return "Cannot open \(p): \(String(cString: strerror(e)))"
        case .readFailed(let o, let e): return "Read error at byte \(o): \(String(cString: strerror(e)))"
        case .writeFailed(let o, let e): return "Write error at byte \(o): \(String(cString: strerror(e)))"
        case .readOnly: return "This source was opened read-only."
        case .misaligned: return "Writes to a raw device must be sector-aligned."
        case .invalid(let m): return m
        case .cancelled: return "Cancelled."
        }
    }
    public var isPermissionDenied: Bool {
        if case .openFailed(_, let e) = self { return e == EACCES || e == EPERM }
        return false
    }
}

/// A random-access, sector-aware view of a raw device or a disk-image file.
/// Reads are always clamped to the end of the source and, for raw devices, expanded to whole sectors.
public final class DiskSource: @unchecked Sendable {
    public let path: String
    public let fd: Int32
    public let size: UInt64
    public let sectorSize: Int
    public let isDevice: Bool
    public let isWritable: Bool
    public var bsdName: String? {
        let n = (path as NSString).lastPathComponent
        if n.hasPrefix("rdisk") { return String(n.dropFirst()) }
        if n.hasPrefix("disk") { return n }
        return nil
    }
    public var displayName: String { (path as NSString).lastPathComponent }
    public var sectorCount: UInt64 { size / UInt64(sectorSize) }

    private static let maxIO = 1 << 20

    /// Open a path directly (works for image files and for devices the user may already read).
    public convenience init(path: String, writable: Bool = false) throws {
        let fd = open(path, writable ? O_RDWR : O_RDONLY)
        if fd < 0 { throw DiskError.openFailed(path: path, errno: errno) }
        try self.init(fd: fd, path: path, writable: writable)
    }

    /// Adopt an already-open descriptor (e.g. one received from the privileged helper).
    public init(fd: Int32, path: String, writable: Bool, sectorSizeOverride: Int? = nil) throws {
        self.fd = fd
        self.path = path
        self.isWritable = writable
        var st = stat()
        if fstat(fd, &st) != 0 { let e = errno; close(fd); throw DiskError.openFailed(path: path, errno: e) }
        let isChar = (st.st_mode & S_IFMT) == S_IFCHR
        let isBlk = (st.st_mode & S_IFMT) == S_IFBLK
        if isChar || isBlk {
            var bs: UInt32 = 0, bc: UInt64 = 0
            if cs_disk_geometry(fd, &bs, &bc) != 0 { let e = errno; close(fd); throw DiskError.openFailed(path: path, errno: e) }
            self.isDevice = true
            self.sectorSize = Int(bs)
            self.size = UInt64(bs) * bc
        } else {
            self.isDevice = false
            self.sectorSize = sectorSizeOverride ?? 512
            self.size = UInt64(st.st_size)
            _ = cs_set_nocache(fd)
        }
    }

    deinit { close(fd) }

    /// Read `length` bytes at `offset`. Returns fewer bytes only at the end of the source.
    public func read(offset: UInt64, length: Int) throws -> [UInt8] {
        guard length > 0, offset < size else { return [] }
        let wantEnd = Swift.min(size, offset + UInt64(length))
        var start = offset, end = wantEnd
        if isDevice {
            let ss = UInt64(sectorSize)
            start = offset - offset % ss
            end = Swift.min(size, (wantEnd + ss - 1) / ss * ss)
        }
        let total = Int(end - start)
        var buf = [UInt8](repeating: 0, count: total)
        var done = 0
        while done < total {
            let chunk = Swift.min(Self.maxIO, total - done)
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress!.advanced(by: done), chunk, off_t(start) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw DiskError.readFailed(offset: start + UInt64(done), errno: errno)
            }
            if n == 0 { buf.removeLast(total - done); break }
            done += n
        }
        let skip = Int(offset - start)
        let take = Swift.min(Int(wantEnd - offset), buf.count - skip)
        if take <= 0 { return [] }
        if skip == 0 && take == buf.count { return buf }
        return Array(buf[skip..<(skip + take)])
    }

    /// Like `read`, but unreadable sectors come back as zeros instead of throwing.
    /// Returns the data and the number of bytes that could not be read.
    public func readTolerant(offset: UInt64, length: Int) -> (data: [UInt8], badBytes: Int) {
        if let d = try? read(offset: offset, length: length) { return (d, 0) }
        guard offset < size else { return ([], 0) }
        let end = Swift.min(size, offset + UInt64(length))
        var out = [UInt8](); out.reserveCapacity(Int(end - offset))
        var bad = 0
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
        if isDevice, offset % UInt64(sectorSize) != 0 || bytes.count % sectorSize != 0 { throw DiskError.misaligned }
        guard offset + UInt64(bytes.count) <= size else { throw DiskError.invalid("Write beyond end of disk.") }
        var done = 0
        while done < bytes.count {
            let chunk = Swift.min(Self.maxIO, bytes.count - done)
            let n = bytes.withUnsafeBytes { raw in
                pwrite(fd, raw.baseAddress!.advanced(by: done), chunk, off_t(offset) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw DiskError.writeFailed(offset: offset + UInt64(done), errno: errno)
            }
            done += n
        }
    }

    public func flush() { _ = cs_full_fsync(fd) }
}
