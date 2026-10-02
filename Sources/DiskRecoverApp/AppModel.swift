import SwiftUI
import DiskRecoverCore

enum SourceTab: String, CaseIterable, Identifiable {
    case partitions = "Partitions"
    case lost = "Find Lost Partitions"
    case files = "Files"
    case photos = "Photo Recovery"
    case tools = "Tools"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .partitions: return "internaldrive"
        case .lost: return "magnifyingglass"
        case .files: return "folder"
        case .photos: return "photo.on.rectangle.angled"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var disks: [DiskInfo] = []
    var loadingDisks = false
    var imageSessions: [SourceSession] = []
    var selection: String?
    @ObservationIgnored private var diskSessions: [String: SourceSession] = [:]
    @ObservationIgnored var readHelper: HelperClient?

    var selectedSession: SourceSession? {
        guard let s = selection else { return nil }
        if let i = imageSessions.first(where: { $0.id == s }) { return i }
        return diskSessions[s]
    }

    func refreshDisks() async {
        loadingDisks = true
        let list = await Task.detached { DiskEnumerator.listDisks() }.value
        disks = list
        loadingDisks = false
    }

    func session(for disk: DiskInfo) -> SourceSession {
        let id = "disk:\(disk.id)"
        if let s = diskSessions[id] { s.diskInfo = disk; return s }
        let s = SourceSession(id: id, title: disk.title, devicePath: disk.devicePath, diskInfo: disk, app: self)
        diskSessions[id] = s
        return s
    }

    func select(disk: DiskInfo) {
        let s = session(for: disk)
        selection = s.id
        if s.state == .closed { Task { await s.open() } }
    }

    func openImage(_ url: URL) {
        let id = "image:\(url.path)"
        if imageSessions.contains(where: { $0.id == id }) { selection = id; return }
        let s = SourceSession(id: id, title: url.lastPathComponent, devicePath: url.path, diskInfo: nil, app: self)
        imageSessions.append(s)
        selection = id
        Task { await s.open() }
    }

    func closeImage(_ s: SourceSession) {
        s.cancelAll()
        imageSessions.removeAll { $0.id == s.id }
        if selection == s.id { selection = nil }
    }

    /// The read-only privileged helper, started on demand and shared by every disk.
    func ensureReadHelper() async throws -> HelperClient {
        if let h = readHelper, h.isConnected { return h }
        let h = HelperClient(allowWrite: false)
        guard let exe = Bundle.main.executablePath else { throw HelperError.failed("Cannot locate the app executable.") }
        try await h.authorize(executable: exe)
        readHelper = h
        return h
    }
}

struct VolumeChoice: Identifiable, Hashable {
    var id: String
    var title: String
    var startLBA: UInt64
    var sectorCount: UInt64
    var fs: FSInfo?
    var fromSearch: Bool
}

enum FSLoadState: Equatable {
    case idle
    case scanning(Double)
    case ready
    case failed(String)
}

struct OperationState {
    var running = false
    var progress: Double = 0
    var message = ""
    var error: String?
}

@MainActor @Observable
final class SourceSession: Identifiable {
    enum State: Equatable { case closed, opening, needsAccess, ready, failed(String) }

    let id: String
    let title: String
    let devicePath: String
    var diskInfo: DiskInfo?
    @ObservationIgnored unowned let app: AppModel
    var isImage: Bool { diskInfo == nil }

    var state: State = .closed
    var tab: SourceTab = .partitions
    @ObservationIgnored var source: DiskSource?
    var analysis: TableAnalysis?
    var partitionFS: [UInt64: FSInfo] = [:]       // by start LBA

    // Find lost partitions
    var searchMode: SearchModeChoice = .quick
    var search = OperationState()
    var found: [FoundPartition] = []
    var searchFoundCount = 0
    var searchRan = false
    @ObservationIgnored var searchTask: Task<Void, Never>?

    // Files
    var selectedVolumeID: String?
    var fsState: FSLoadState = .idle
    @ObservationIgnored var index: FSIndex?
    @ObservationIgnored var reader: FileSystemReader?
    var indexVersion = 0
    @ObservationIgnored var scanTask: Task<Void, Never>?
    var recover = OperationState()
    var recoverSummary: RecoverSummary?
    @ObservationIgnored var recoverTask: Task<Void, Never>?

    // Photo recovery
    var carveFamilies: Set<String> = Set(CarveFormats.families.map { $0.id })
    var carveVolumeID: String = "whole"
    var carveFreeSpaceOnly = false
    var carveFineAlignment = true
    var carveDestination: URL?
    var carve = OperationState()
    var carveProgress = CarveProgress()
    var carveFiles: [CarvedFile] = []
    var carveSpeed: Double = 0
    @ObservationIgnored var carveTask: Task<Void, Never>?

    // Tools
    var imaging = OperationState()
    var imagingResult: String?
    @ObservationIgnored var imagingTask: Task<Void, Never>?
    var sectorLBA: UInt64 = 0

    init(id: String, title: String, devicePath: String, diskInfo: DiskInfo?, app: AppModel) {
        self.id = id; self.title = title; self.devicePath = devicePath; self.diskInfo = diskInfo; self.app = app
    }

    var bsdName: String? { diskInfo?.id }
    var isSystemDisk: Bool { diskInfo?.isSystemDisk ?? false }
    var sectorSize: Int { source?.sectorSize ?? 512 }

    func cancelAll() {
        searchTask?.cancel(); scanTask?.cancel(); recoverTask?.cancel(); carveTask?.cancel(); imagingTask?.cancel()
    }

    // MARK: opening

    func open() async {
        state = .opening
        do {
            source = try DiskSource(path: devicePath)
            state = .ready
            await reloadAnalysis()
        } catch let e as DiskError where e.isPermissionDenied {
            state = .needsAccess
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func authorizeAndOpen() async {
        state = .opening
        do {
            let h = try await app.ensureReadHelper()
            source = try h.open(path: devicePath, writable: false)
            state = .ready
            await reloadAnalysis()
        } catch HelperError.cancelled {
            state = .needsAccess
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reloadAnalysis() async {
        guard let src = source else { return }
        let result = await Task.detached { () -> (TableAnalysis, [UInt64: FSInfo]) in
            let a = PartitionTableParser.analyze(src)
            var fs: [UInt64: FSInfo] = [:]
            for p in a.partitions where !p.isExtendedContainer {
                if let b = try? src.read(offset: p.startLBA * UInt64(src.sectorSize), length: 8192),
                   let info = FilesystemDetector.detect(sector: b, sectorSize: src.sectorSize) { fs[p.startLBA] = info }
            }
            return (a, fs)
        }.value
        analysis = result.0
        partitionFS = result.1
    }

    // MARK: volumes

    var volumeChoices: [VolumeChoice] {
        var out: [VolumeChoice] = []
        let ss = UInt64(sectorSize)
        if let a = analysis {
            for p in a.partitions where !p.isExtendedContainer {
                let fs = partitionFS[p.startLBA]
                let name = fs?.displayName ?? p.typeDescription
                out.append(VolumeChoice(id: "t\(p.startLBA)", title: "Partition \(p.index) — \(name), \(Format.bytes(p.sectorCount * ss))" + (p.name.isEmpty ? "" : " “\(p.name)”"),
                                        startLBA: p.startLBA, sectorCount: p.sectorCount, fs: fs, fromSearch: false))
            }
        }
        for f in found where !out.contains(where: { $0.startLBA == f.startLBA }) {
            out.append(VolumeChoice(id: "f\(f.startLBA)", title: "Found by search — \(f.fs.displayName), \(Format.bytes(f.sectorCount * ss)) at sector \(f.startLBA)",
                                    startLBA: f.startLBA, sectorCount: f.sectorCount, fs: f.fs, fromSearch: true))
        }
        if analysis?.scheme != .bareFilesystem, let src = source {
            out.append(VolumeChoice(id: "whole", title: "Entire disk (\(Format.bytes(src.size)))", startLBA: 0, sectorCount: src.sectorCount, fs: nil, fromSearch: false))
        }
        return out
    }

    func volume(for choice: VolumeChoice) -> Volume? {
        guard let src = source else { return nil }
        return Volume(src: src, startLBA: choice.startLBA, sectors: choice.sectorCount)
    }

    // MARK: lost partition search

    func runSearch() {
        guard let src = source, !search.running else { return }
        search = OperationState(running: true, progress: 0, message: "Starting…")
        found = []
        searchRan = false
        let mode: SearchMode = searchMode == .quick ? .quick : .deep
        let current = analysis?.partitions ?? []
        searchTask = Task {
            let outcome: Result<[FoundPartition], Error> = await Task.detached {
                let searcher = PartitionSearcher(source: src, mode: mode)
                do {
                    let r = try searcher.run(currentTable: current) { frac, count in
                        Task { @MainActor in
                            self.search.progress = frac
                            self.searchFoundCount = count
                            self.search.message = count == 1 ? "1 filesystem found" : "\(count) filesystems found"
                        }
                    }
                    return .success(r)
                } catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let r): found = r; searchRan = true; search = OperationState(); search.message = "Done"
            case .failure(let e):
                search = OperationState(); search.error = e is CancellationError ? "Search cancelled." : e.localizedDescription
            }
        }
    }

    func cancelSearch() { searchTask?.cancel() }

    // MARK: writing (partition tables, boot sectors)

    /// Open the disk for writing. Images are reopened read-write; physical disks need a separate,
    /// write-enabled administrator helper and every volume on the disk must be unmounted first.
    func openForWriting() async throws -> DiskSource {
        if isImage { return try DiskSource(path: devicePath, writable: true) }
        guard let info = diskInfo else { throw DiskError.invalid("Unknown disk.") }
        if info.isSystemDisk { throw DiskError.invalid("This is your Mac's startup disk. macOS protects it, and changing its partition table would be dangerous.") }
        try DiskEnumerator.unmountDisk(info.id)
        let h = HelperClient(allowWrite: true)
        guard let exe = Bundle.main.executablePath else { throw HelperError.failed("Cannot locate the app executable.") }
        try await h.authorize(executable: exe)
        writeHelper = h
        return try h.open(path: devicePath, writable: true)
    }
    @ObservationIgnored var writeHelper: HelperClient?
}

enum SearchModeChoice: String, CaseIterable, Identifiable {
    case quick = "Quick"
    case deep = "Deep (every sector)"
    var id: String { rawValue }
}
