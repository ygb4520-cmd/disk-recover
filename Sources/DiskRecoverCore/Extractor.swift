import Foundation

public struct RecoverSummary {
    public var filesRecovered = 0
    public var foldersCreated = 0
    public var bytes: UInt64 = 0
    public var failures: [(path: String, message: String)] = []
    public var warnings: [(path: String, message: String)] = []
    public var destination: URL
}

public enum Extractor {
    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "")
        if s.isEmpty || s == "." || s == ".." { s = "_" + s }
        while s.utf8.count > 250 { s.removeLast() }
        return s
    }

    /// First free name in `dir`: "name", then "name (2)", "name (3)", ...
    public static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        let clean = sanitize(name)
        var url = dir.appendingPathComponent(clean)
        if !fm.fileExists(atPath: url.path) { return url }
        let ns = clean as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            url = dir.appendingPathComponent(candidate)
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }

    /// Recover the given entries (files, or folders with everything below them) into `destination`.
    public static func recover(ids: [Int], index: FSIndex, reader: FileSystemReader, destination: URL, preservePaths: Bool = false,
                               progress: @escaping (_ currentPath: String, _ filesDone: Int, _ bytes: UInt64) -> Void) throws -> RecoverSummary {
        var summary = RecoverSummary(destination: destination)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        func recoverEntry(_ id: Int, into dir: URL) throws {
            try Task.checkCancellation()
            let e = index[id]
            if e.isDirectory {
                let url = uniqueURL(in: dir, name: e.name)
                do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
                catch { summary.failures.append((index.path(of: id), error.localizedDescription)); return }
                summary.foldersCreated += 1
                for c in index.children[id] ?? [] { try recoverEntry(c, into: url) }
                if let m = e.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: url.path) }
                return
            }
            var dir = dir
            if preservePaths {
                // Rebuild the original folder chain under the destination instead of dumping files flat.
                var chain: [String] = []
                var p = e.parent
                while p >= 0, chain.count < 64 { chain.append(sanitize(index[p].name)); p = index[p].parent }
                for name in chain.reversed() { dir.appendPathComponent(name, isDirectory: true) }
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let url = uniqueURL(in: dir, name: e.name)
            progress(index.path(of: id), summary.filesRecovered, summary.bytes)
            guard fm.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
                summary.failures.append((index.path(of: id), "Cannot create \(url.path)")); return
            }
            do {
                let r = try reader.extract(e) { chunk in try h.write(contentsOf: chunk) }
                try h.close()
                summary.filesRecovered += 1
                summary.bytes += r.bytes
                for w in r.warnings { summary.warnings.append((index.path(of: id), w)) }
                if let m = e.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: url.path) }
            } catch is CancellationError {
                try? h.close(); try? fm.removeItem(at: url)
                throw CancellationError()
            } catch {
                try? h.close()
                summary.failures.append((index.path(of: id), error.localizedDescription))
                try? fm.removeItem(at: url)
            }
        }
        for id in ids { try recoverEntry(id, into: destination) }
        return summary
    }
}

/// Works out whether a destination folder lives on the disk being recovered (writing there can destroy the very data you want back).
public enum DestinationCheck {
    public static func isOnDisk(url: URL, wholeDisk bsd: String) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        let dev = (from as NSString).lastPathComponent
        let whole = wholeDiskName(dev)
        if whole == bsd { return true }
        // APFS volumes live in a synthesized container; ask diskutil which physical disk backs it.
        if let plist = runPlist(["info", "-plist", dev]),
           let stores = plist["APFSPhysicalStores"] as? [[String: Any]] {
            for s in stores {
                if let id = s["APFSPhysicalStore"] as? String, wholeDiskName(id) == bsd { return true }
            }
        }
        return false
    }

    public static func wholeDiskName(_ bsd: String) -> String {
        // disk3s5 -> disk3 ; disk3 -> disk3
        guard bsd.hasPrefix("disk") else { return bsd }
        let digits = bsd.dropFirst(4).prefix { $0.isNumber }
        return "disk" + digits
    }

    static func runPlist(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
