import Foundation

/// Bounds-tolerant little/big-endian readers. Corrupt disk structures routinely point outside
/// their buffers, so out-of-range reads return 0 instead of trapping.
public extension Array where Element == UInt8 {
    @inline(__always) func u8(_ o: Int) -> UInt8 { (o >= 0 && o < count) ? self[o] : 0 }

    func le16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[o]) | UInt16(self[o + 1]) << 8
    }
    func le32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func le64(_ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= count else { return 0 }
        return UInt64(le32(o)) | UInt64(le32(o + 4)) << 32
    }
    func be16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[o]) << 8 | UInt16(self[o + 1])
    }
    func be32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }
    func be64(_ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= count else { return 0 }
        return UInt64(be32(o)) << 32 | UInt64(be32(o + 4))
    }

    /// Latin-1 text, stopping at the first NUL, trailing spaces trimmed.
    func ascii(_ o: Int, _ n: Int) -> String {
        guard o >= 0, n > 0, o < count else { return "" }
        let end = Swift.min(count, o + n)
        var out = [UInt8]()
        for b in self[o..<end] { if b == 0 { break }; out.append(b) }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    func utf16le(_ o: Int, chars: Int) -> String {
        guard o >= 0, chars > 0 else { return "" }
        var units = [UInt16]()
        for i in 0..<chars {
            guard o + i * 2 + 2 <= count else { break }
            let u = le16(o + i * 2)
            units.append(u)
        }
        return String(decoding: units, as: UTF16.self)
    }

    func hasPrefix(_ bytes: [UInt8], at o: Int = 0) -> Bool {
        guard o >= 0, o + bytes.count <= count else { return false }
        for i in 0..<bytes.count where self[o + i] != bytes[i] { return false }
        return true
    }

    var isAllZero: Bool { !contains { $0 != 0 } }

    mutating func put16le(_ o: Int, _ v: UInt16) {
        guard o + 2 <= count else { return }
        self[o] = UInt8(v & 0xFF); self[o + 1] = UInt8(v >> 8)
    }
    mutating func put32le(_ o: Int, _ v: UInt32) {
        guard o + 4 <= count else { return }
        for i in 0..<4 { self[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }
    mutating func put64le(_ o: Int, _ v: UInt64) {
        guard o + 8 <= count else { return }
        for i in 0..<8 { self[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) }
    }
    mutating func put(_ o: Int, _ bytes: [UInt8]) {
        guard o >= 0, o + bytes.count <= count else { return }
        for (i, b) in bytes.enumerated() { self[o + i] = b }
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

/// 128-bit GUID stored in on-disk (mixed-endian) byte order.
public struct GUID: Hashable, CustomStringConvertible {
    public var bytes: [UInt8]
    public init(bytes: [UInt8]) { self.bytes = bytes.count == 16 ? bytes : [UInt8](repeating: 0, count: 16) }
    public static var zero: GUID { GUID(bytes: [UInt8](repeating: 0, count: 16)) }
    public var isZero: Bool { bytes.isAllZero }
    public static func random() -> GUID {
        var b = (0..<16).map { _ in UInt8.random(in: 0...255) }
        b[7] = (b[7] & 0x0F) | 0x40   // version 4 (stored in time_hi_and_version, little-endian field)
        b[8] = (b[8] & 0x3F) | 0x80
        return GUID(bytes: b)
    }
    public init?(_ s: String) {
        let hex = s.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        var raw = [UInt8]()
        var idx = hex.startIndex
        for _ in 0..<16 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            raw.append(b); idx = next
        }
        // text form is big-endian for the first three fields
        let d = [raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6]] + Array(raw[8...])
        self.bytes = d
    }
    public var description: String {
        let b = bytes
        func h(_ r: [UInt8]) -> String { r.map { String(format: "%02X", $0) }.joined() }
        return "\(h([b[3], b[2], b[1], b[0]]))-\(h([b[5], b[4]]))-\(h([b[7], b[6]]))-\(h(Array(b[8..<10])))-\(h(Array(b[10..<16])))"
    }
}

public enum Format {
    public static func bytes(_ n: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useAll]
        return f.string(fromByteCount: Int64(clamping: n))
    }
}
