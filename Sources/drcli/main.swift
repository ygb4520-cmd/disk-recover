import Foundation
import DiskRecoverCore

// drcli — command-line front end for the Disk Recover core. Handy for scripting and for verifying the core on disk images.

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

if CommandLine.arguments.contains("--helper") { HelperServer.run(arguments: CommandLine.arguments) }
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    usage: drcli <command> <disk-or-image> [options]
      analyze                      show the partition table and problems
      search [--deep] [--write mbr|gpt]
                                   find lost partitions (optionally write them as a new table)
      ls [--part N | --start LBA --sectors N] [--deleted]
      recover [--part N | --start LBA --sectors N] --dest DIR [--deleted]
      carve  [--part N | --start LBA --sectors N] --dest DIR [--free] [--types jpg,png,...]
      repair-boot --start LBA --sectors N [--apply]
      image --out FILE
      hex --lba N
    """)
    exit(0)
}
if cmd == "helper-test" {
    // Exercise the fd-passing helper without an admin prompt: ask it to open a file, then read through the descriptor.
    guard args.count >= 2 else { die("usage: drcli helper-test FILE") }
    let c = HelperClient(allowWrite: false)
    do {
        try c.launchUnprivilegedForTesting(executable: CommandLine.arguments[0])
        let s = try c.open(path: args[1], writable: false)
        print("helper returned fd: size=\(s.size) sector=\(s.sectorSize) first bytes=\((try s.read(offset: 0, length: 4)).map { String(format: "%02x", $0) }.joined())")
        do { _ = try c.open(path: args[1], writable: true); print("UNEXPECTED: write open allowed") }
        catch { print("write request refused as expected: \(error.localizedDescription)") }
        do { _ = try c.open(path: "/nonexistent/x", writable: false) } catch { print("missing file reported: \(error.localizedDescription)") }
    } catch { die("helper test failed: \(error.localizedDescription)") }
    exit(0)
}
guard args.count >= 2 else { die("missing disk/image path") }
let path = args[1]
func opt(_ name: String) -> String? { if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }; return nil }
func flag(_ name: String) -> Bool { args.contains(name) }

let writable = (cmd == "search" && opt("--write") != nil) || (cmd == "repair-boot" && flag("--apply"))
let src: DiskSource
do { src = try DiskSource(path: path, writable: writable) } catch { die(error.localizedDescription) }

func resolveVolume() -> Volume {
    if let n = opt("--part").flatMap(Int.init) {
        let a = PartitionTableParser.analyze(src)
        guard let p = a.partitions.first(where: { $0.index == n }) else { die("no partition \(n)") }
        return Volume(src: src, startLBA: p.startLBA, sectors: p.sectorCount)
    }
    if let s = opt("--start").flatMap(UInt64.init), let n = opt("--sectors").flatMap(UInt64.init) {
        return Volume(src: src, startLBA: s, sectors: n)
    }
    return Volume(src: src, offset: 0, length: src.size)
}

func runSync<T>(_ body: @escaping () throws -> T) -> Result<T, Error> {
    var result: Result<T, Error>!
    let sem = DispatchSemaphore(value: 0)
    Task.detached { result = Result { try body() }; sem.signal() }
    sem.wait()
    return result
}

switch cmd {
case "analyze":
    let a = PartitionTableParser.analyze(src)
    print("Disk: \(Format.bytes(src.size)), sector size \(a.sectorSize), scheme: \(a.scheme.rawValue)")
    for i in a.issues { print("  [\(i.severity)] \(i.message)") }
    for p in a.partitions {
        let fs = (try? src.read(offset: p.startLBA * UInt64(a.sectorSize), length: 4096)).flatMap { FilesystemDetector.detect(sector: $0, sectorSize: a.sectorSize) }
        print(String(format: "  #%d %@ start=%llu end=%llu size=%@ fs=%@ %@", p.index, p.typeDescription, p.startLBA, p.endLBA,
                     Format.bytes(p.byteSize(sectorSize: a.sectorSize)), fs?.displayName ?? "?", p.name))
    }

case "search":
    let mode: SearchMode = flag("--deep") ? .deep : .quick
    let a = PartitionTableParser.analyze(src)
    let searcher = PartitionSearcher(source: src, mode: mode)
    let r = runSync { try searcher.run(currentTable: a.partitions) { f, n in
        if Int(f * 100) % 10 == 0 { FileHandle.standardError.write(Data("\r\(Int(f * 100))% (\(n) found)".utf8)) } } }
    FileHandle.standardError.write(Data("\n".utf8))
    guard case .success(let found) = r else { die("\(r)") }
    for f in found {
        print(String(format: "%@ start=%llu end=%llu size=%@ fs=%@ label=%@ conf=%d%@%@%@", "•", f.startLBA, f.endLBA,
                     Format.bytes(f.sectorCount * UInt64(src.sectorSize)), f.fs.displayName, f.fs.label ?? "-", f.confidence,
                     f.matchesCurrentTable ? " [in table]" : "", f.viaBackup ? " [via backup]" : "", f.selected ? " [selected]" : ""))
        if !f.note.isEmpty { print("    \(f.note)") }
    }
    if let scheme = opt("--write") {
        let planned = found.filter { $0.selected }.map { PlannedPartition(found: $0, existing: a.partitions) }
        do {
            let writes = try TableWriter.plan(scheme: scheme == "gpt" ? .gpt : .mbr, partitions: planned, disk: src, existing: a)
            let backup = try SectorWriter.apply(writes, to: src, reason: "drcli search --write")
            print("Wrote \(scheme.uppercased()) with \(planned.count) partitions. Backup: \(backup.path)")
        } catch { die(error.localizedDescription) }
    }

case "ls":
    let vol = resolveVolume()
    do {
        let fs = try FileSystemFactory.open(volume: vol, sectorSize: src.sectorSize)
        let idx = try runSync { try fs.scan { _ in } }.get()
        print("\(fs.info.displayName) volume '\(idx.volumeLabel ?? "")': \(idx.fileCount) files, \(idx.deletedCount) deleted")
        for w in idx.warnings { print("  note: \(w)") }
        for e in idx.entries where !flag("--deleted") || e.isDeleted {
            print(String(format: "%@ %@ %10llu  %@", e.isDeleted ? "D" : " ", e.isDirectory ? "d" : "-", e.size, idx.path(of: e.id)) + (e.isDeleted ? "  [\(e.health.rawValue)]" : ""))
        }
    } catch { die(error.localizedDescription) }

case "recover":
    guard let dest = opt("--dest") else { die("--dest required") }
    let vol = resolveVolume()
    do {
        let fs = try FileSystemFactory.open(volume: vol, sectorSize: src.sectorSize)
        let idx = try runSync { try fs.scan { _ in } }.get()
        let top = idx.entries.filter { flag("--deleted") ? ($0.isDeleted && !$0.isDirectory) : $0.parent == -1 }.map { $0.id }
        let s = try runSync { try Extractor.recover(ids: top, index: idx, reader: fs, destination: URL(fileURLWithPath: dest)) { _, _, _ in } }.get()
        print("Recovered \(s.filesRecovered) files, \(s.foldersCreated) folders, \(Format.bytes(s.bytes)); \(s.failures.count) failed, \(s.warnings.count) warnings")
        for f in s.failures { print("  FAILED \(f.path): \(f.message)") }
        for w in s.warnings { print("  warn \(w.path): \(w.message)") }
    } catch { die(error.localizedDescription) }

case "carve":
    guard let dest = opt("--dest") else { die("--dest required") }
    let vol = resolveVolume()
    var ranges = [vol.offset..<(vol.offset + vol.length)]
    var align = 512
    if flag("--free") {
        let fs: FileSystemReader
        do { fs = try FileSystemFactory.open(volume: vol, sectorSize: src.sectorSize) } catch { die(error.localizedDescription) }
        ranges = (try? runSync { try fs.freeRanges() }.get()) ?? ranges
        align = fs.info.clusterSize
        print("free space: \(ranges.count) ranges, \(Format.bytes(ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }))")
    }
    var families = Set(CarveFormats.families.map { $0.id })
    if let t = opt("--types") { families = Set(t.split(separator: ",").map(String.init)) }
    let carver = Carver(source: src, options: CarveOptions(families: families, ranges: ranges, alignment: align, destination: URL(fileURLWithPath: dest)))
    let r = runSync { try carver.run(progress: { _ in }, onFile: { f in print("  \(f.url.lastPathComponent)  \(f.length) bytes\(f.partial ? " (partial)" : "")") }) }
    switch r { case .success(let p): print("Carved \(p.filesFound) files (\(p.partialFiles) partial): \(p.perFamily.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    case .failure(let e): die(e.localizedDescription) }

case "repair-boot":
    let vol = resolveVolume()
    guard let boot = try? vol.read(0, 4096) else { die("cannot read volume") }
    var fsInfo = FilesystemDetector.detect(sector: boot, sectorSize: src.sectorSize)
    if fsInfo == nil {
        for off in [UInt64(6 * 512), UInt64(12 * 512), vol.length - 512] {
            if let b = try? vol.read(off, 4096), let i = FilesystemDetector.detect(sector: b, sectorSize: src.sectorSize) { fsInfo = i; break }
        }
    }
    guard let info = fsInfo else { die("no filesystem (or backup boot sector) found") }
    let start = vol.offset / UInt64(src.sectorSize)
    let st = BootRepair.assess(src, start: start, fs: info)
    print(st.summary)
    if flag("--apply") {
        guard st.supported, !st.primaryOK, st.backupOK else { die("nothing to repair") }
        do {
            let w = try BootRepair.plan(src, start: start, fs: info, backupToPrimary: true)
            let b = try SectorWriter.apply(w, to: src, reason: "repair boot sector")
            print("Boot sector restored. Backup of old sectors: \(b.path)")
        } catch { die(error.localizedDescription) }
    }

case "image":
    guard let out = opt("--out") else { die("--out required") }
    let r = runSync { try DiskImager.copy(from: src, range: 0..<src.size, to: URL(fileURLWithPath: out)) { _ in } }
    switch r { case .success(let i): print("Copied \(Format.bytes(i.bytesCopied)), unreadable: \(i.unreadableBytes) bytes")
    case .failure(let e): die(e.localizedDescription) }

case "hex":
    guard let lba = opt("--lba").flatMap(UInt64.init) else { die("--lba required") }
    let d = (try? src.readSectors(lba: lba, count: 1)) ?? []
    for row in stride(from: 0, to: d.count, by: 16) {
        let chunk = d[row..<Swift.min(row + 16, d.count)]
        print(String(format: "%04X  ", row) + chunk.map { String(format: "%02X", $0) }.joined(separator: " ") + "  " + String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." }))
    }

default: die("unknown command \(cmd)")
}
