import XCTest
@testable import DiskRecoverCore

final class CoreTests: XCTestCase {
    func tempImage(sectors: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dr-\(UUID().uuidString).img")
        try Data(count: sectors * 512).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCRC32KnownValue() { XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF43926) }

    func testGUIDRoundTrip() {
        let g = GUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")!
        XCTAssertEqual(g.description, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")
        XCTAssertEqual(g, PartitionTypes.efiSystem)
    }

    func testBytesReadersAreBoundsSafe() {
        let b: [UInt8] = [1, 2, 3]
        XCTAssertEqual(b.le32(0), 0)       // not enough bytes: 0, not a crash
        XCTAssertEqual(b.le16(1), 0x0302)
    }

    func testMBRWriteThenAnalyzeRoundTrip() throws {
        let url = try tempImage(sectors: 20_000)
        let src = try DiskSource(path: url.path, writable: true)
        let empty = PartitionTableParser.analyze(src)
        XCTAssertEqual(empty.scheme, .none)
        let fs = FSInfo(kind: .fat32, displayName: "FAT32", totalSectors: 4000, label: nil, clusterSize: 4096, bytesPerSector: 512)
        let a = FoundPartition(startLBA: 63, sectorCount: 4000, fs: fs, confidence: 80, viaBackup: false, note: "")
        let b = FoundPartition(startLBA: 5000, sectorCount: 8000, fs: fs, confidence: 80, viaBackup: false, note: "")
        let planned = [a, b].map { PlannedPartition(found: $0) }
        let writes = try TableWriter.plan(scheme: .mbr, partitions: planned, disk: src, existing: empty)
        _ = try SectorWriter.apply(writes, to: src, reason: "test")
        let after = PartitionTableParser.analyze(src)
        XCTAssertEqual(after.scheme, .mbr)
        XCTAssertEqual(after.partitions.map { $0.startLBA }, [63, 5000])
        XCTAssertEqual(after.partitions.map { $0.sectorCount }, [4000, 8000])
    }

    func testGPTWriteThenAnalyzeAndBackupRecovery() throws {
        let url = try tempImage(sectors: 20_000)
        let src = try DiskSource(path: url.path, writable: true)
        let fs = FSInfo(kind: .ntfs, displayName: "NTFS", totalSectors: 5000, label: nil, clusterSize: 4096, bytesPerSector: 512)
        let p = PlannedPartition(found: FoundPartition(startLBA: 2048, sectorCount: 5000, fs: fs, confidence: 90, viaBackup: false, note: ""))
        let writes = try TableWriter.plan(scheme: .gpt, partitions: [p], disk: src, existing: PartitionTableParser.analyze(src))
        _ = try SectorWriter.apply(writes, to: src, reason: "test")
        var a = PartitionTableParser.analyze(src)
        XCTAssertEqual(a.scheme, .gpt)
        XCTAssertTrue(a.primaryGPTValid && a.backupGPTValid)
        // Destroy the primary GPT: the backup must still describe the same partition.
        try src.write(offset: 512, bytes: [UInt8](repeating: 0, count: 512 * 33))
        a = PartitionTableParser.analyze(src)
        XCTAssertFalse(a.primaryGPTValid)
        XCTAssertTrue(a.backupGPTValid)
        XCTAssertEqual(a.partitions.first?.startLBA, 2048)
    }

    func testBackupRestoreUndoesWrite() throws {
        let url = try tempImage(sectors: 4096)
        let src = try DiskSource(path: url.path, writable: true)
        try src.write(offset: 0, bytes: [UInt8](repeating: 0xAB, count: 512))
        let w = [SectorWrite(lba: 0, bytes: [UInt8](repeating: 0xCD, count: 512))]
        let backup = try SectorWriter.apply(w, to: src, reason: "test")
        XCTAssertEqual(try src.read(offset: 0, length: 1), [0xCD])
        try SectorWriter.restore(backup: backup, to: src)
        XCTAssertEqual(try src.read(offset: 0, length: 1), [0xAB])
    }

    func testCarverFindsPNGAndSkipsGarbage() throws {
        // Minimal valid PNG: signature + IHDR + IEND.
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            var c = [UInt8](repeating: 0, count: 4); c.put32le(0, UInt32(data.count).byteSwapped)
            return c + Array(type.utf8) + data + [0, 0, 0, 0]
        }
        let ihdr = [UInt8](repeating: 0, count: 13)
        let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", [UInt8](repeating: 7, count: 40)) + chunk("IEND", [])
        var img = [UInt8](repeating: 0, count: 512 * 64)
        img.put(512 * 5, png)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dr-\(UUID().uuidString).img")
        try Data(img).write(to: url)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("dr-out-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: out) }
        let src = try DiskSource(path: url.path)
        let carver = Carver(source: src, options: CarveOptions(families: ["png"], ranges: [0..<src.size], destination: out))
        var found: [CarvedFile] = []
        let p = try carver.run(progress: { _ in }, onFile: { found.append($0) })
        XCTAssertEqual(p.filesFound, 1)
        XCTAssertEqual(found.first?.offset, 512 * 5)
        XCTAssertEqual(found.first?.length, UInt64(png.count))
        XCTAssertEqual(try Data(contentsOf: found[0].url), Data(png))
    }

    func testUniqueURLNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dr-u-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        XCTAssertEqual(Extractor.uniqueURL(in: dir, name: "a.txt").lastPathComponent, "a (2).txt")
        XCTAssertEqual(Extractor.uniqueURL(in: dir, name: "x/y.txt").lastPathComponent, "x_y.txt")
    }
}
