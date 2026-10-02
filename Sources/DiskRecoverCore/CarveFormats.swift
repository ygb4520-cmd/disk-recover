import Foundation

/// Sequential reader over a disk region used by the format sizers. Offsets are relative to the file start.
final class StreamReader {
    let src: DiskSource
    let base: UInt64
    let limit: UInt64          // absolute end of readable region
    private var win: [UInt8] = []
    private var winStart: UInt64 = 0
    var available: UInt64 { limit > base ? limit - base : 0 }

    init(src: DiskSource, base: UInt64, limit: UInt64) { self.src = src; self.base = base; self.limit = limit }

    func bytes(_ rel: UInt64, _ n: Int) -> [UInt8] {
        guard n > 0, rel < available else { return [] }
        let want = Int(Swift.min(UInt64(n), available - rel))
        if rel >= winStart, rel + UInt64(want) <= winStart + UInt64(win.count) {
            let s = Int(rel - winStart)
            return Array(win[s..<(s + want)])
        }
        let fetch = Int(Swift.min(UInt64(Swift.max(want, 256 << 10)), available - rel))
        win = src.readTolerant(offset: base + rel, length: fetch).data
        winStart = rel
        return Array(win.prefix(want))
    }
    func u8(_ rel: UInt64) -> UInt8 { bytes(rel, 1).first ?? 0 }
    func le16(_ rel: UInt64) -> UInt16 { bytes(rel, 2).le16(0) }
    func le32(_ rel: UInt64) -> UInt32 { bytes(rel, 4).le32(0) }
    func le64(_ rel: UInt64) -> UInt64 { bytes(rel, 8).le64(0) }
    func be16(_ rel: UInt64) -> UInt16 { bytes(rel, 2).be16(0) }
    func be32(_ rel: UInt64) -> UInt32 { bytes(rel, 4).be32(0) }
    func be64(_ rel: UInt64) -> UInt64 { bytes(rel, 8).be64(0) }

    /// First occurrence of `pattern` in [from, upTo).
    func find(_ pattern: [UInt8], from: UInt64, upTo: UInt64) -> UInt64? {
        var pos = from
        let end = Swift.min(upTo, available)
        let chunk = 1 << 20
        while pos < end {
            let d = bytes(pos, Int(Swift.min(UInt64(chunk + pattern.count), end - pos + UInt64(pattern.count))))
            if d.count < pattern.count { return nil }
            let first = pattern[0]
            var i = 0
            let limitI = d.count - pattern.count
            while i <= limitI {
                if d[i] == first {
                    var ok = true
                    for k in 1..<pattern.count where d[i + k] != pattern[k] { ok = false; break }
                    if ok { let hit = pos + UInt64(i); return hit < end ? hit : nil }
                }
                i += 1
            }
            if UInt64(d.count) < UInt64(chunk) { return nil }
            pos += UInt64(chunk)
        }
        return nil
    }
}

enum SizeResult {
    case exact(UInt64, ext: String?)     // structure fully parsed
    case partial(UInt64, ext: String?)   // header valid but data ran out / was damaged
    case invalid                         // false positive
}

public enum Category: String, CaseIterable { case pictures = "Pictures", video = "Video", audio = "Audio", documents = "Documents", archives = "Archives", other = "Other" }

public struct FileFamily: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let extensions: String
    public let category: Category
}

struct Signature {
    var family: String
    var magic: [UInt8]
    var magicOffset = 0
    var minSize: UInt64 = 64
    var maxSize: UInt64
    var defaultExt: String
    var sizer: (StreamReader) -> SizeResult
}

public enum CarveFormats {
    public static let families: [FileFamily] = [
        FileFamily(id: "jpg", title: "JPEG image", extensions: "jpg", category: .pictures),
        FileFamily(id: "png", title: "PNG image", extensions: "png", category: .pictures),
        FileFamily(id: "gif", title: "GIF image", extensions: "gif", category: .pictures),
        FileFamily(id: "bmp", title: "BMP image", extensions: "bmp", category: .pictures),
        FileFamily(id: "tiff", title: "TIFF and camera RAW", extensions: "tif, cr2", category: .pictures),
        FileFamily(id: "riff", title: "RIFF containers", extensions: "avi, wav, webp", category: .video),
        FileFamily(id: "bmff", title: "MPEG-4 family", extensions: "mp4, mov, m4a, 3gp, heic", category: .video),
        FileFamily(id: "mkv", title: "Matroska / WebM", extensions: "mkv, webm", category: .video),
        FileFamily(id: "mp3", title: "MP3 audio", extensions: "mp3", category: .audio),
        FileFamily(id: "ogg", title: "Ogg audio/video", extensions: "ogg", category: .audio),
        FileFamily(id: "pdf", title: "PDF document", extensions: "pdf", category: .documents),
        FileFamily(id: "ole", title: "Legacy Office", extensions: "doc, xls, ppt, msg", category: .documents),
        FileFamily(id: "rtf", title: "Rich Text", extensions: "rtf", category: .documents),
        FileFamily(id: "zip", title: "ZIP and ZIP-based documents", extensions: "zip, docx, xlsx, pptx, odt, epub, jar", category: .archives),
        FileFamily(id: "7z", title: "7-Zip archive", extensions: "7z", category: .archives),
        FileFamily(id: "rar", title: "RAR archive", extensions: "rar", category: .archives),
        FileFamily(id: "sqlite", title: "SQLite database", extensions: "sqlite", category: .other),
        FileFamily(id: "pe", title: "Windows executable", extensions: "exe, dll", category: .other),
    ]

    static let all: [Signature] = {
        let mb: UInt64 = 1 << 20, gb: UInt64 = 1 << 30
        return [
            Signature(family: "jpg", magic: [0xFF, 0xD8, 0xFF], minSize: 256, maxSize: 200 * mb, defaultExt: "jpg", sizer: Sizers.jpeg),
            Signature(family: "png", magic: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], minSize: 67, maxSize: 200 * mb, defaultExt: "png", sizer: Sizers.png),
            Signature(family: "gif", magic: Array("GIF87a".utf8), minSize: 35, maxSize: 200 * mb, defaultExt: "gif", sizer: Sizers.gif),
            Signature(family: "gif", magic: Array("GIF89a".utf8), minSize: 35, maxSize: 200 * mb, defaultExt: "gif", sizer: Sizers.gif),
            Signature(family: "bmp", magic: [0x42, 0x4D], minSize: 100, maxSize: 512 * mb, defaultExt: "bmp", sizer: Sizers.bmp),
            Signature(family: "tiff", magic: [0x49, 0x49, 0x2A, 0x00], minSize: 256, maxSize: 2 * gb, defaultExt: "tif", sizer: Sizers.tiff),
            Signature(family: "tiff", magic: [0x4D, 0x4D, 0x00, 0x2A], minSize: 256, maxSize: 2 * gb, defaultExt: "tif", sizer: Sizers.tiff),
            Signature(family: "riff", magic: Array("RIFF".utf8), minSize: 44, maxSize: 4 * gb, defaultExt: "avi", sizer: Sizers.riff),
            Signature(family: "bmff", magic: Array("ftyp".utf8), magicOffset: 4, minSize: 64, maxSize: 16 * gb, defaultExt: "mp4", sizer: Sizers.bmff),
            Signature(family: "mkv", magic: [0x1A, 0x45, 0xDF, 0xA3], minSize: 128, maxSize: 16 * gb, defaultExt: "mkv", sizer: Sizers.mkv),
            Signature(family: "mp3", magic: Array("ID3".utf8), minSize: 1024, maxSize: 512 * mb, defaultExt: "mp3", sizer: Sizers.mp3),
            Signature(family: "mp3", magic: [0xFF, 0xFB], minSize: 4096, maxSize: 512 * mb, defaultExt: "mp3", sizer: Sizers.mp3),
            Signature(family: "ogg", magic: Array("OggS".utf8), minSize: 256, maxSize: 2 * gb, defaultExt: "ogg", sizer: Sizers.ogg),
            Signature(family: "pdf", magic: Array("%PDF-".utf8), minSize: 256, maxSize: 2 * gb, defaultExt: "pdf", sizer: Sizers.pdf),
            Signature(family: "ole", magic: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], minSize: 1024, maxSize: 1 * gb, defaultExt: "doc", sizer: Sizers.ole),
            Signature(family: "rtf", magic: Array("{\\rtf".utf8), minSize: 32, maxSize: 100 * mb, defaultExt: "rtf", sizer: Sizers.rtf),
            Signature(family: "zip", magic: [0x50, 0x4B, 0x03, 0x04], minSize: 100, maxSize: 4 * gb, defaultExt: "zip", sizer: Sizers.zip),
            Signature(family: "7z", magic: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], minSize: 32, maxSize: 4 * gb, defaultExt: "7z", sizer: Sizers.sevenZip),
            Signature(family: "rar", magic: Array("Rar!".utf8) + [0x1A, 0x07], minSize: 32, maxSize: 4 * gb, defaultExt: "rar", sizer: Sizers.rar),
            Signature(family: "sqlite", magic: Array("SQLite format 3".utf8) + [0], minSize: 512, maxSize: 4 * gb, defaultExt: "sqlite", sizer: Sizers.sqlite),
            Signature(family: "pe", magic: [0x4D, 0x5A], minSize: 512, maxSize: 1 * gb, defaultExt: "exe", sizer: Sizers.pe),
        ]
    }()
}

// MARK: - Sizers

enum Sizers {
    // JPEG: walk marker segments so thumbnails embedded in EXIF don't end the file early.
    static func jpeg(_ r: StreamReader) -> SizeResult {
        guard r.bytes(0, 3) == [0xFF, 0xD8, 0xFF] else { return .invalid }
        let fourth = r.u8(3)
        guard fourth >= 0xC0 && fourth != 0xFF else { return .invalid }
        var pos: UInt64 = 2
        var sawSOF = false
        let cap = Swift.min(r.available, 200 << 20)
        for _ in 0..<200_000 {
            guard pos + 4 <= cap else { break }
            let h = r.bytes(pos, 4)
            guard h[0] == 0xFF else { return sawSOF ? .partial(pos, ext: nil) : .invalid }
            let m = h[1]
            if m == 0xD9 { return sawSOF ? .exact(pos + 2, ext: nil) : .invalid }
            if m == 0xFF { pos += 1; continue }
            if m == 0xD8 || m == 0x01 || (0xD0...0xD7).contains(m) || m == 0x00 { pos += 2; continue }
            let len = UInt64(h.be16(2))
            guard len >= 2 else { return sawSOF ? .partial(pos, ext: nil) : .invalid }
            if (0xC0...0xCF).contains(m), m != 0xC4, m != 0xC8, m != 0xCC { sawSOF = true }
            pos += 2 + len
            if m == 0xDA {
                guard sawSOF else { return .invalid }
                // Entropy-coded data: runs until a marker that isn't a stuffed byte or restart.
                var found = false
                scan: while pos < cap {
                    let chunk = r.bytes(pos, 1 << 16)
                    if chunk.isEmpty { break }
                    var i = 0
                    while i + 1 < chunk.count {
                        if chunk[i] == 0xFF {
                            let n = chunk[i + 1]
                            if n != 0x00 && !(0xD0...0xD7).contains(n) && n != 0xFF { pos += UInt64(i); found = true; break scan }
                            i += n == 0xFF ? 1 : 2
                        } else { i += 1 }
                    }
                    pos += UInt64(chunk.count - 1)
                    if chunk.count < 2 { break }
                }
                if !found { return .partial(Swift.min(pos, cap), ext: nil) }
            }
        }
        return sawSOF ? .partial(Swift.min(pos, cap), ext: nil) : .invalid
    }

    static func png(_ r: StreamReader) -> SizeResult {
        guard r.bytes(0, 8) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return .invalid }
        guard r.be32(8) == 13, r.bytes(12, 4) == Array("IHDR".utf8) else { return .invalid }
        var pos: UInt64 = 8
        let cap = Swift.min(r.available, 200 << 20)
        while pos + 12 <= cap {
            let h = r.bytes(pos, 8)
            let len = UInt64(h.be32(0))
            let type = Array(h[4..<8])
            guard type.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }), len < 0x7FFF_FFFF else { return pos > 33 ? .partial(pos, ext: nil) : .invalid }
            pos += 12 + len
            if type == Array("IEND".utf8) { return .exact(pos, ext: nil) }
        }
        return pos > 33 ? .partial(Swift.min(pos, cap), ext: nil) : .invalid
    }

    static func gif(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 13)
        guard h.count == 13 else { return .invalid }
        var pos: UInt64 = 13
        if h[10] & 0x80 != 0 { pos += 3 << (UInt64(h[10] & 7) + 1) }
        var images = 0
        let cap = Swift.min(r.available, 200 << 20)
        func skipSubBlocks() -> Bool {
            while pos < cap {
                let n = UInt64(r.u8(pos)); pos += 1
                if n == 0 { return true }
                pos += n
            }
            return false
        }
        for _ in 0..<1_000_000 {
            guard pos < cap else { break }
            let b = r.u8(pos)
            if b == 0x3B { return images > 0 ? .exact(pos + 1, ext: nil) : .invalid }
            if b == 0x21 { pos += 2; if !skipSubBlocks() { break } }
            else if b == 0x2C {
                let d = r.bytes(pos, 10)
                guard d.count == 10 else { break }
                pos += 10
                if d[9] & 0x80 != 0 { pos += 3 << (UInt64(d[9] & 7) + 1) }
                pos += 1
                if !skipSubBlocks() { break }
                images += 1
            } else { break }
        }
        return images > 0 ? .partial(Swift.min(pos, cap), ext: nil) : .invalid
    }

    static func bmp(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 30)
        guard h.count == 30, h.le32(6) == 0 else { return .invalid }
        let size = UInt64(h.le32(2)), off = UInt64(h.le32(10)), dib = h.le32(14)
        guard [12, 40, 52, 56, 64, 108, 124].contains(dib), off >= 14 + UInt64(dib), off < size, size <= (512 << 20) else { return .invalid }
        let w = Int32(bitPattern: h.le32(18)), ht = Int32(bitPattern: h.le32(22))
        guard dib == 12 || (w > 0 && w < 100_000 && ht != 0 && abs(Int64(ht)) < 100_000) else { return .invalid }
        guard h.le16(26) == 1 else { return .invalid }
        return .exact(size, ext: nil)
    }

    static func pdf(_ r: StreamReader) -> SizeResult {
        guard r.bytes(0, 5) == Array("%PDF-".utf8), r.u8(5) == 0x31 || r.u8(5) == 0x32 else { return .invalid }
        let cap = Swift.min(r.available, 2 << 30)
        var pos: UInt64 = 0
        var lastEnd: UInt64?
        while let hit = r.find(Array("%%EOF".utf8), from: pos, upTo: cap) {
            var end = hit + 5
            for _ in 0..<2 { let b = r.u8(end); if b == 0x0A || b == 0x0D { end += 1 } }
            lastEnd = end
            // An incremental update or linearized second half continues with "N G obj".
            let peek = r.bytes(end, 24)
            var i = 0
            while i < peek.count, peek[i] == 0x0A || peek[i] == 0x0D || peek[i] == 0x20 { i += 1 }
            var digits = 0
            while i < peek.count, peek[i] >= 0x30 && peek[i] <= 0x39 { i += 1; digits += 1 }
            var continues = false
            if digits > 0, i < peek.count, peek[i] == 0x20 {
                i += 1
                var d2 = 0
                while i < peek.count, peek[i] >= 0x30 && peek[i] <= 0x39 { i += 1; d2 += 1 }
                if d2 > 0, i + 4 <= peek.count, peek[i] == 0x20, Array(peek[(i + 1)..<(i + 4)]) == Array("obj".utf8) { continues = true }
            }
            if !continues { return .exact(end, ext: nil) }
            pos = end
        }
        if let e = lastEnd { return .exact(e, ext: nil) }
        return .invalid
    }

    // MARK: ZIP

    static func zip(_ r: StreamReader) -> SizeResult {
        var pos: UInt64 = 0
        let cap = Swift.min(r.available, 4 << 30)
        var names: [String] = []
        var mimetype: String?
        var needScan = false
        walk: for entry in 0..<2_000_000 {
            guard pos + 4 <= cap else { break }
            let sig = r.le32(pos)
            switch sig {
            case 0x04034B50:
                let h = r.bytes(pos, 30)
                guard h.count == 30 else { break walk }
                let flags = h.le16(6), method = h.le16(8)
                let comp = UInt64(h.le32(18)), nameLen = UInt64(h.le16(26)), extra = UInt64(h.le16(28))
                if entry < 64 {
                    let n = String(decoding: r.bytes(pos + 30, Int(nameLen)), as: UTF8.self)
                    names.append(n)
                    if n == "mimetype", method == 0, comp < 200 { mimetype = String(decoding: r.bytes(pos + 30 + nameLen + extra, Int(comp)), as: UTF8.self) }
                }
                if (flags & 8 != 0 && comp == 0) || comp == 0xFFFF_FFFF { needScan = true; break walk }
                pos += 30 + nameLen + extra + comp
                if flags & 8 != 0, r.le32(pos) == 0x08074B50 { pos += 16 }
            case 0x02014B50:
                let h = r.bytes(pos, 46)
                guard h.count == 46 else { break walk }
                pos += 46 + UInt64(h.le16(28)) + UInt64(h.le16(30)) + UInt64(h.le16(32))
            case 0x06064B50:
                pos += 12 + r.le64(pos + 4)
            case 0x07064B50:
                pos += 20
            case 0x06054B50:
                let end = pos + 22 + UInt64(r.le16(pos + 20))
                return .exact(end, ext: zipExtension(names: names, mimetype: mimetype))
            default:
                break walk
            }
        }
        if needScan {
            // Streamed archives (sizes after the data): look for an end-of-central-directory record whose offsets add up.
            var from: UInt64 = 22
            while let hit = r.find([0x50, 0x4B, 0x05, 0x06], from: from, upTo: cap) {
                let e = r.bytes(hit, 22)
                if e.count == 22 {
                    let cdSize = UInt64(e.le32(12)), cdOff = UInt64(e.le32(16))
                    if cdOff + cdSize == hit || (cdOff + cdSize <= hit && hit - (cdOff + cdSize) < 4096 && r.le32(cdOff) == 0x02014B50) {
                        return .exact(hit + 22 + UInt64(e.le16(20)), ext: zipExtension(names: names, mimetype: mimetype))
                    }
                }
                from = hit + 4
            }
        }
        return names.isEmpty ? .invalid : .partial(Swift.min(pos, cap), ext: zipExtension(names: names, mimetype: mimetype))
    }

    static func zipExtension(names: [String], mimetype: String?) -> String {
        if let m = mimetype {
            if m.hasSuffix("opendocument.text") { return "odt" }
            if m.hasSuffix("opendocument.spreadsheet") { return "ods" }
            if m.hasSuffix("opendocument.presentation") { return "odp" }
            if m.contains("epub") { return "epub" }
        }
        if names.contains(where: { $0.hasPrefix("word/") }) { return "docx" }
        if names.contains(where: { $0.hasPrefix("xl/") }) { return "xlsx" }
        if names.contains(where: { $0.hasPrefix("ppt/") }) { return "pptx" }
        if names.contains("AndroidManifest.xml") { return "apk" }
        if names.contains(where: { $0.hasPrefix("META-INF/") }) { return "jar" }
        return "zip"
    }

    static func sevenZip(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 32)
        guard h.count == 32, h[6] == 0, CRC32.checksum(Array(h[12..<32])) == h.le32(8) else { return .invalid }
        let end = 32 + h.le64(12) + h.le64(20)
        return end <= r.available ? .exact(end, ext: nil) : .partial(r.available, ext: nil)
    }

    static func rar(_ r: StreamReader) -> SizeResult {
        let head = r.bytes(0, 8)
        let cap = Swift.min(r.available, 4 << 30)
        if head.count == 8, head[6] == 0x00 {                    // RAR 4.x
            var pos: UInt64 = 7
            for _ in 0..<1_000_000 {
                guard pos + 11 <= cap else { break }
                let h = r.bytes(pos, 11)
                let type = h[2], flags = h.le16(3), hs = UInt64(h.le16(5))
                guard hs >= 7 else { break }
                var add: UInt64 = 0
                if flags & 0x8000 != 0 || type == 0x74 { add = UInt64(h.le32(7)) }
                pos += hs + add
                if type == 0x7B { return .exact(pos, ext: nil) }
                if ![0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A].contains(type) { break }
            }
            return pos > 7 ? .partial(Swift.min(pos, cap), ext: nil) : .invalid
        }
        if head.count == 8, head[6] == 0x01, head[7] == 0x00 {   // RAR 5
            var pos: UInt64 = 8
            func vint(_ at: inout UInt64) -> UInt64? {
                var v: UInt64 = 0
                for i in 0..<10 {
                    let b = r.u8(at); at += 1
                    v |= UInt64(b & 0x7F) << UInt64(7 * i)
                    if b & 0x80 == 0 { return v }
                }
                return nil
            }
            for _ in 0..<1_000_000 {
                guard pos + 8 <= cap else { break }
                var p = pos + 4
                guard let hsz = vint(&p), let type = vint(&p), let flags = vint(&p) else { break }
                let afterSize = p
                var dataSize: UInt64 = 0
                if flags & 1 != 0 { guard vint(&p) != nil else { break } }
                if flags & 2 != 0 { guard let d = vint(&p) else { break }; dataSize = d }
                pos = afterSize + hsz + dataSize
                if type == 5 { return .exact(pos, ext: nil) }
                if type > 5 { break }
            }
            return pos > 8 ? .partial(Swift.min(pos, cap), ext: nil) : .invalid
        }
        return .invalid
    }

    static func riff(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 12)
        guard h.count == 12 else { return .invalid }
        let kind = String(decoding: h[8..<12], as: UTF8.self)
        let ext: String
        switch kind {
        case "AVI ": ext = "avi"
        case "WAVE": ext = "wav"
        case "WEBP": ext = "webp"
        default: return .invalid
        }
        let size = UInt64(h.le32(4)) + 8
        guard size >= 44 || ext == "webp" && size >= 20, size < (4 << 30) else { return .invalid }
        let end = size + (size & 1)
        return end <= r.available ? .exact(size, ext: ext) : .partial(r.available, ext: ext)
    }

    static func bmff(_ r: StreamReader) -> SizeResult {
        let head = r.bytes(0, 16)
        guard head.count == 16, head.be32(0) >= 12, head.be32(0) <= 256 else { return .invalid }
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        var ext = "mp4"
        switch brand {
        case "qt  ": ext = "mov"
        case "M4A ", "M4B ": ext = "m4a"
        case "heic", "heix", "hevc", "heim", "heis", "mif1", "msf1": ext = "heic"
        case "avif", "avis": ext = "avif"
        case "crx ": ext = "cr3"
        default: if brand.hasPrefix("3g") { ext = "3gp" }
        }
        let known: Set<String> = ["ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "pnot", "meta", "mfra", "moof", "styp", "sidx", "pdin", "junk", "udta", "prfl", "ssix", "emsg", "iloc", "iinf", "idat"]
        var pos: UInt64 = 0
        var sawMoov = false, sawMdat = false, sawMeta = false
        let cap = Swift.min(r.available, 16 << 30)
        for _ in 0..<100_000 {
            guard pos + 8 <= cap else { break }
            let h = r.bytes(pos, 16)
            var size = UInt64(h.be32(0))
            let type = String(decoding: h[4..<8], as: UTF8.self)
            guard known.contains(type) else { break }
            var header: UInt64 = 8
            if size == 1 { size = h.be64(8); header = 16 }
            if size == 0 { return (sawMoov || sawMeta) ? .partial(cap, ext: ext) : .invalid }
            guard size >= header else { break }
            if type == "moov" { sawMoov = true }
            if type == "mdat" { sawMdat = true }
            if type == "meta" { sawMeta = true }
            pos += size
        }
        if (sawMoov && sawMdat) || (sawMeta && sawMdat) { return pos <= cap ? .exact(pos, ext: ext) : .partial(cap, ext: ext) }
        return (sawMoov || sawMdat) ? .partial(Swift.min(pos, cap), ext: ext) : .invalid
    }

    // MARK: Matroska

    static func mkv(_ r: StreamReader) -> SizeResult {
        func vint(_ at: UInt64, keepMarker: Bool) -> (value: UInt64, length: Int, unknown: Bool)? {
            let b = r.bytes(at, 8)
            guard let f = b.first, f != 0 else { return nil }
            let len = f.leadingZeroBitCount + 1
            guard b.count >= len else { return nil }
            var v = UInt64(keepMarker ? f : f & (0xFF >> UInt8(len)))
            var allOnes = (f & (0xFF >> UInt8(len))) == (0xFF >> UInt8(len))
            for i in 1..<len { v = v << 8 | UInt64(b[i]); if b[i] != 0xFF { allOnes = false } }
            return (v, len, allOnes && !keepMarker)
        }
        guard let idLen = vint(0, keepMarker: true), idLen.value == 0x1A45DFA3, let sz = vint(UInt64(idLen.length), keepMarker: false) else { return .invalid }
        let ebmlEnd = UInt64(idLen.length + sz.length) + sz.value
        let head = r.bytes(0, Int(Swift.min(ebmlEnd, 256)))
        let ext = String(decoding: head, as: UTF8.self).contains("webm") ? "webm" : "mkv"
        guard let segID = vint(ebmlEnd, keepMarker: true), segID.value == 0x18538067,
              let segSize = vint(ebmlEnd + UInt64(segID.length), keepMarker: false) else { return .invalid }
        if segSize.unknown { return .partial(Swift.min(r.available, 64 << 20), ext: ext) }
        let end = ebmlEnd + UInt64(segID.length + segSize.length) + segSize.value
        return end <= r.available ? .exact(end, ext: ext) : .partial(r.available, ext: ext)
    }

    // MARK: MP3

    static func mp3(_ r: StreamReader) -> SizeResult {
        var pos: UInt64 = 0
        let hasID3 = r.bytes(0, 3) == Array("ID3".utf8)
        if hasID3 {
            let h = r.bytes(0, 10)
            guard h.count == 10, h[3] < 5, h[6..<10].allSatisfy({ $0 < 0x80 }) else { return .invalid }
            let size = (UInt64(h[6]) << 21) | (UInt64(h[7]) << 14) | (UInt64(h[8]) << 7) | UInt64(h[9])
            pos = 10 + size + (h[5] & 0x10 != 0 ? 10 : 0)
        }
        let br1: [[Int]] = [[], [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384], [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]]
        let br2: [[Int]] = [[], [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]]
        let sr: [[Int]] = [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
        var frames = 0
        let cap = Swift.min(r.available, 512 << 20)
        var firstVersion = -1, firstLayer = -1
        while pos + 4 <= cap {
            let h = r.be32(pos)
            guard h >> 21 == 0x7FF else { break }
            let version = Int((h >> 19) & 3)            // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
            let layerBits = Int((h >> 17) & 3)          // 3 = Layer I, 2 = Layer II, 1 = Layer III
            let bri = Int((h >> 12) & 0xF), sri = Int((h >> 10) & 3), pad = Int((h >> 9) & 1)
            guard version != 1, layerBits != 0, bri != 0, bri != 15, sri != 3 else { break }
            if firstVersion < 0 { firstVersion = version; firstLayer = layerBits }
            guard version == firstVersion, layerBits == firstLayer else { break }
            let layer = 4 - layerBits                   // 1, 2 or 3
            let bitrate = (version == 3 ? br1[layer][bri] : br2[layer][bri]) * 1000
            let rate = sr[version][sri]
            let len: Int
            switch layer {
            case 1: len = (12 * bitrate / rate + pad) * 4
            case 2: len = 144 * bitrate / rate + pad
            default: len = (version == 3 ? 144 : 72) * bitrate / rate + pad
            }
            guard len > 4 else { break }
            pos += UInt64(len)
            frames += 1
        }
        guard frames >= (hasID3 ? 4 : 32) else { return .invalid }
        if r.bytes(pos, 3) == Array("TAG".utf8) { pos += 128 }
        return .exact(Swift.min(pos, cap), ext: nil)
    }

    static func ogg(_ r: StreamReader) -> SizeResult {
        var pos: UInt64 = 0
        let cap = Swift.min(r.available, 2 << 30)
        var pages = 0
        while pos + 27 <= cap {
            let h = r.bytes(pos, 27)
            guard h.count == 27, h.hasPrefix(Array("OggS".utf8)), h[4] == 0 else { break }
            let n = Int(h[26])
            let table = r.bytes(pos + 27, n)
            guard table.count == n else { break }
            let payload = table.reduce(0) { $0 + UInt64($1) }
            pos += 27 + UInt64(n) + payload
            pages += 1
            if h[5] & 0x04 != 0 { return .exact(pos, ext: nil) }
        }
        return pages >= 2 ? .partial(Swift.min(pos, cap), ext: nil) : .invalid
    }

    // MARK: OLE2

    static func ole(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 512)
        guard h.count == 512, h.le16(28) == 0xFFFE else { return .invalid }
        let shift = Int(h.le16(30))
        guard shift == 9 || shift == 12 else { return .invalid }
        let ss = 1 << shift
        let numFAT = Int(h.le32(44)), dirStart = h.le32(48)
        guard numFAT > 0, numFAT <= 4096 else { return .invalid }
        var fatSectors: [UInt32] = []
        for i in 0..<109 where fatSectors.count < numFAT { let v = h.le32(76 + i * 4); if v < 0xFFFFFFF0 { fatSectors.append(v) } }
        var difat = h.le32(68)
        var guardN = 0
        while fatSectors.count < numFAT, difat < 0xFFFFFFF0, guardN < 4096 {
            let d = r.bytes((UInt64(difat) + 1) * UInt64(ss), ss)
            guard d.count == ss else { break }
            for i in 0..<(ss / 4 - 1) where fatSectors.count < numFAT { let v = d.le32(i * 4); if v < 0xFFFFFFF0 { fatSectors.append(v) } }
            difat = d.le32(ss - 4); guardN += 1
        }
        var fat: [UInt32] = []
        var maxUsed: Int64 = -1
        for s in fatSectors {
            let d = r.bytes((UInt64(s) + 1) * UInt64(ss), ss)
            guard d.count == ss else { return .partial(Swift.min(r.available, (UInt64(maxUsed) + 2) * UInt64(ss)), ext: nil) }
            for i in 0..<(ss / 4) {
                let v = d.le32(i * 4)
                if v != 0xFFFFFFFF { maxUsed = Int64(fat.count + i) }
            }
            fat += (0..<(ss / 4)).map { d.le32($0 * 4) }
        }
        guard maxUsed >= 0 else { return .invalid }
        let total = (UInt64(maxUsed) + 2) * UInt64(ss)
        // Classify by stream names in the directory.
        var ext = "ole"
        var sec = dirStart
        var hops = 0
        scan: while sec < 0xFFFFFFF0, Int(sec) < fat.count, hops < 256 {
            let d = r.bytes((UInt64(sec) + 1) * UInt64(ss), ss)
            for i in stride(from: 0, to: d.count - 127, by: 128) {
                let nameLen = Int(d.le16(i + 64))
                guard nameLen >= 2, nameLen <= 64 else { continue }
                let name = d.utf16le(i, chars: nameLen / 2 - 1)
                if name == "WordDocument" { ext = "doc"; break scan }
                if name == "Workbook" || name == "Book" { ext = "xls"; break scan }
                if name == "PowerPoint Document" { ext = "ppt"; break scan }
                if name.hasPrefix("__substg1.0_") || name == "__properties_version1.0" { ext = "msg"; break scan }
                if name == "VisioDocument" { ext = "vsd"; break scan }
            }
            sec = fat[Int(sec)]; hops += 1
        }
        return total <= r.available ? .exact(total, ext: ext) : .partial(r.available, ext: ext)
    }

    static func rtf(_ r: StreamReader) -> SizeResult {
        var depth = 0
        var pos: UInt64 = 0
        let cap = Swift.min(r.available, 100 << 20)
        var escaped = false
        while pos < cap {
            let chunk = r.bytes(pos, 1 << 16)
            if chunk.isEmpty { break }
            for (i, b) in chunk.enumerated() {
                if escaped { escaped = false; continue }
                if b == 0x5C { escaped = true }
                else if b == 0x7B { depth += 1 }
                else if b == 0x7D { depth -= 1; if depth == 0 { return .exact(pos + UInt64(i) + 1, ext: nil) } }
                else if b == 0 { return .partial(pos + UInt64(i), ext: nil) }
            }
            pos += UInt64(chunk.count)
        }
        return .invalid
    }

    static func sqlite(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 100)
        guard h.count == 100 else { return .invalid }
        var pageSize = UInt64(h.be16(16))
        if pageSize == 1 { pageSize = 65536 }
        guard pageSize >= 512, pageSize & (pageSize - 1) == 0, h[18] <= 2, h[19] <= 2, h.be32(92) == h.be32(24) else { return .invalid }
        let pages = UInt64(h.be32(28))
        guard pages > 0 else { return .invalid }
        let size = pages * pageSize
        return size <= r.available ? .exact(size, ext: nil) : .partial(r.available, ext: nil)
    }

    static func pe(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 64)
        guard h.count == 64 else { return .invalid }
        let peOff = UInt64(h.le32(0x3C))
        guard peOff >= 64, peOff < 4096, r.bytes(peOff, 4) == [0x50, 0x45, 0, 0] else { return .invalid }
        let coff = r.bytes(peOff + 4, 20)
        let sections = Int(coff.le16(2)), optSize = UInt64(coff.le16(16)), characteristics = coff.le16(18)
        guard sections > 0, sections <= 96, optSize >= 96 else { return .invalid }
        let opt = r.bytes(peOff + 24, Int(optSize))
        var end: UInt64 = 0
        let plus = opt.le16(0) == 0x20B
        let dd = plus ? 112 : 96
        if opt.count >= dd + 40 { end = Swift.max(end, UInt64(opt.le32(dd + 32)) + UInt64(opt.le32(dd + 36))) }
        for i in 0..<sections {
            let s = r.bytes(peOff + 24 + optSize + UInt64(i * 40), 40)
            guard s.count == 40 else { return .invalid }
            end = Swift.max(end, UInt64(s.le32(20)) + UInt64(s.le32(16)))
        }
        guard end > 512, end <= r.available, end < (1 << 30) else { return .invalid }
        return .exact(end, ext: characteristics & 0x2000 != 0 ? "dll" : "exe")
    }

    // MARK: TIFF / camera RAW

    static func tiff(_ r: StreamReader) -> SizeResult {
        let h = r.bytes(0, 16)
        guard h.count == 16 else { return .invalid }
        let little = h[0] == 0x49
        func rd16(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(little ? b.le16(o) : b.be16(o)) }
        func rd32(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(little ? b.le32(o) : b.be32(o)) }
        let isCR2 = h[8] == 0x43 && h[9] == 0x52
        let cap = Swift.min(r.available, 2 << 30)
        var maxEnd: UInt64 = 8
        var queue: [UInt64] = [rd32(h, 4)]
        var visited = Set<UInt64>()
        let typeSize: [UInt64] = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4]
        var ifdsRead = 0
        while let off = queue.popLast() {
            guard off >= 8, off < cap, !visited.contains(off), visited.count < 64 else { continue }
            visited.insert(off)
            let nb = r.bytes(off, 2)
            guard nb.count == 2 else { continue }
            let n = Int(rd16(nb, 0))
            guard n > 0, n < 1024 else { continue }
            let e = r.bytes(off + 2, n * 12 + 4)
            guard e.count == n * 12 + 4 else { continue }
            ifdsRead += 1
            maxEnd = Swift.max(maxEnd, off + 2 + UInt64(n * 12 + 4))
            var offsets: [UInt64] = [], counts: [UInt64] = []
            func values(_ o: Int, type: Int, count: UInt64) -> [UInt64] {
                let ts = typeSize[Swift.min(type, 13)]
                guard (type == 3 || type == 4), count > 0, count <= 200_000 else { return [] }
                let total = ts * count
                let raw: [UInt8]
                if total <= 4 { raw = Array(e[(o + 8)..<(o + 12)]) }
                else { raw = r.bytes(rd32(e, o + 8), Int(total)) }
                guard raw.count >= Int(total) else { return [] }
                return (0..<Int(count)).map { type == 3 ? rd16(raw, $0 * 2) : rd32(raw, $0 * 4) }
            }
            for i in 0..<n {
                let o = i * 12
                let tag = rd16(e, o), type = Int(rd16(e, o + 2)), count = rd32(e, o + 4)
                let ts = type >= 1 && type <= 13 ? typeSize[type] : 0
                let total = ts * count
                if total > 4 { maxEnd = Swift.max(maxEnd, rd32(e, o + 8) + total) }
                switch tag {
                case 273, 324: offsets = values(o, type: type, count: count)
                case 279, 325: counts = values(o, type: type, count: count)
                case 330: for v in values(o, type: type, count: count) { queue.append(v) }
                case 0x8769, 0x8825, 0xA005: queue.append(rd32(e, o + 8))
                default: break
                }
            }
            if offsets.count == counts.count { for (a, b) in Swift.zip(offsets, counts) { maxEnd = Swift.max(maxEnd, a + b) } }
            else if offsets.count == 1 && counts.isEmpty { maxEnd = Swift.max(maxEnd, offsets[0]) }
            let next = rd32(e, n * 12)
            if next != 0 { queue.append(next) }
        }
        guard ifdsRead > 0, maxEnd > 8, maxEnd <= cap else { return ifdsRead > 0 ? .partial(Swift.min(maxEnd, cap), ext: isCR2 ? "cr2" : nil) : .invalid }
        return .exact(maxEnd, ext: isCR2 ? "cr2" : nil)
    }
}
