import SwiftUI
import DiskRecoverCore

/// Asks before saving recovered data onto the disk being recovered from.
@MainActor func destinationIsSafe(_ url: URL, for session: SourceSession) -> Bool {
    guard let bsd = session.bsdName, DestinationCheck.isOnDisk(url: url, wholeDisk: bsd) else { return true }
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = "That folder is on the disk you're recovering from"
    a.informativeText = "Saving recovered files back onto the same disk can overwrite the very data you are trying to get back. Choose a folder on a different drive."
    a.addButton(withTitle: "Choose Another Folder")
    a.addButton(withTitle: "Save Here Anyway")
    return a.runModal() == .alertSecondButtonReturn
}

struct FilesView: View {
    @Bindable var session: SourceSession
    @State private var currentDir = -1
    @State private var searchText = ""
    @State private var deletedOnly = false
    @State private var selection = Set<Int>()
    @State private var dirsWithDeleted = Set<Int>()

    var choices: [VolumeChoice] { session.volumeChoices }
    var chosen: VolumeChoice? { choices.first { $0.id == session.selectedVolumeID } }

    var body: some View {
        VStack(spacing: 0) {
            picker.padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            switch session.fsState {
            case .idle: idle
            case .scanning(let p):
                VStack(spacing: 12) { ProgressView(value: p).frame(width: 320); Text("Reading the filesystem… \(Int(p * 100))%").foregroundStyle(.secondary)
                    Button("Cancel") { session.scanTask?.cancel() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m):
                ContentUnavailableView("Cannot read this filesystem", systemImage: "xmark.octagon", description: Text(m))
            case .ready: browser
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugLoadFiles)) { _ in if DebugDriver.enabled { load() } }
        .onAppear { if session.selectedVolumeID == nil, let first = choices.first(where: { $0.fs?.kind.supportsFileRecovery == true }) { session.selectedVolumeID = first.id } }
    }

    var picker: some View {
        HStack {
            Picker("Volume", selection: Binding(get: { session.selectedVolumeID ?? "" }, set: { session.selectedVolumeID = $0; session.fsState = .idle; session.index = nil })) {
                Text("Choose…").tag("")
                ForEach(choices) { Text($0.title).tag($0.id) }
            }
            .frame(maxWidth: 560)
            Button("Load Files") { load() }
                .buttonStyle(.borderedProminent)
                .disabled(chosen == nil || session.fsState != .idle && session.fsState != .ready && !isFailed)
            Spacer()
        }
    }
    var isFailed: Bool { if case .failed = session.fsState { return true }; return false }

    var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundStyle(.secondary)
            if let c = chosen, let fs = c.fs, !fs.kind.supportsFileRecovery {
                Text("\(fs.displayName) volumes can't be browsed or undeleted here.").font(.headline)
                Text("Use Photo Recovery to carve files out of this partition instead.").foregroundStyle(.secondary)
                Button("Open Photo Recovery") { session.carveVolumeID = c.id; session.tab = .photos }
            } else {
                Text("Choose a FAT, exFAT or NTFS volume and click Load Files.").foregroundStyle(.secondary)
                Text("Deleted files are listed too, marked with a trash icon, and can be recovered.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func load() {
        guard let c = chosen, let vol = session.volume(for: c) else { return }
        let ss = session.sectorSize
        session.fsState = .scanning(0)
        currentDir = -1; selection = []; searchText = ""
        session.recoverSummary = nil
        session.scanTask = Task {
            let result: Result<(FileSystemReader, FSIndex, Set<Int>), Error> = await Task.detached {
                do {
                    let r = try FileSystemFactory.open(volume: vol, sectorSize: ss)
                    let idx = try r.scan { p in Task { @MainActor in if case .scanning = session.fsState { session.fsState = .scanning(p) } } }
                    var marked = Set<Int>()
                    for e in idx.entries where e.isDeleted {
                        var p = e.parent, n = 0
                        while p >= 0, n < 256 { marked.insert(p); p = idx[p].parent; n += 1 }
                    }
                    return .success((r, idx, marked))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let (r, idx, marked)):
                session.reader = r; session.index = idx; dirsWithDeleted = marked
                session.indexVersion += 1; session.fsState = .ready
                deletedOnly = idx.deletedCount > 0
            case .failure(let e):
                session.fsState = .failed(e is CancellationError ? "Cancelled." : e.localizedDescription)
            }
        }
    }

    // MARK: browser

    var rows: [FSEntry] {
        guard let idx = session.index else { return [] }
        _ = session.indexVersion
        var list: [FSEntry]
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = []
            for e in idx.entries where e.name.lowercased().contains(q) && (!deletedOnly || e.isDeleted) {
                list.append(e)
                if list.count >= 3000 { break }
            }
        } else {
            list = (idx.children[currentDir] ?? []).map { idx[$0] }
            if deletedOnly { list = list.filter { $0.isDeleted || dirsWithDeleted.contains($0.id) } }
        }
        return list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var browser: some View {
        let idx = session.index!
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { currentDir = idx[currentDir].parent; selection = [] } label: { Image(systemName: "chevron.left") }
                    .disabled(currentDir < 0 || !searchText.isEmpty)
                breadcrumb(idx)
                Spacer()
                Toggle("Deleted only", isOn: $deletedOnly).toggleStyle(.checkbox)
                TextField("Search names", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if let l = idx.volumeLabel, !l.isEmpty { EmptyView() }
            ForEach(idx.warnings, id: \.self) { w in Label(w, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            Table(rows, selection: $selection) {
                TableColumn("Name") { e in
                    HStack(spacing: 6) {
                        Image(systemName: e.isDirectory ? "folder.fill" : "doc").foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                        Text(e.name).strikethrough(false)
                        if e.isDeleted { Image(systemName: "trash").foregroundStyle(.red).font(.caption) }
                        if !e.isDeleted && dirsWithDeleted.contains(e.id) { Badge(text: "has deleted files", color: .red) }
                        if !searchText.isEmpty { Text(idx.path(of: e.id)).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                TableColumn("Size") { e in Text(e.isDirectory ? "—" : Format.bytes(e.size)).foregroundStyle(.secondary) }.width(90)
                TableColumn("Modified") { e in Text(e.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—").foregroundStyle(.secondary) }.width(150)
                TableColumn("Status") { e in
                    if e.isDeleted {
                        Badge(text: e.health.rawValue, color: e.health == .good || e.health == .empty ? .green : .orange)
                    } else if e.health == .unsupported { Badge(text: e.health.rawValue, color: .orange) }
                }.width(150)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Recover to…") { recover(ids: Array(ids)) }.disabled(ids.isEmpty)
            } primaryAction: { ids in
                if let id = ids.first, idx[id].isDirectory, searchText.isEmpty { currentDir = id; selection = [] }
            }
            summaryAndActions(idx)
        }
    }

    func breadcrumb(_ idx: FSIndex) -> some View {
        var chain: [Int] = []
        var c = currentDir
        while c >= 0, chain.count < 64 { chain.append(c); c = idx[c].parent }
        return HStack(spacing: 4) {
            Button(idx.volumeLabel?.isEmpty == false ? idx.volumeLabel! : "Volume") { currentDir = -1; selection = [] }.buttonStyle(.link)
            ForEach(chain.reversed(), id: \.self) { id in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Button(idx[id].name) { currentDir = id; selection = [] }.buttonStyle(.link)
            }
        }
    }

    func summaryAndActions(_ idx: FSIndex) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.recover.running || session.recover.error != nil { ProgressRow(state: session.recover) { session.recoverTask?.cancel() } }
            if let s = session.recoverSummary { SummaryView(summary: s) }
            HStack {
                Text("\(idx.fileCount) files · \(idx.deletedCount) deleted").foregroundStyle(.secondary)
                Spacer()
                Button("Recover All Deleted…") {
                    let ids = idx.entries.filter { $0.isDeleted && !$0.isDirectory }.map { $0.id }
                    recover(ids: ids, preservePaths: true)
                }.disabled(idx.deletedCount == 0 || session.recover.running)
                Button("Recover Selected…") { recover(ids: Array(selection)) }
                    .buttonStyle(.borderedProminent).disabled(selection.isEmpty || session.recover.running)
            }
        }
        .padding(12).background(.bar)
    }

    func recover(ids: [Int], preservePaths: Bool = false) {
        guard !ids.isEmpty, let idx = session.index, let reader = session.reader,
              let dest = Pick.folder(message: "Choose where to save the recovered files. Pick a folder on a different drive.", prompt: "Recover Here"),
              destinationIsSafe(dest, for: session) else { return }
        session.recover = OperationState(running: true, progress: 0, message: "")
        session.recoverSummary = nil
        let total = Double(ids.count)
        session.recoverTask = Task {
            let r: Result<RecoverSummary, Error> = await Task.detached {
                do {
                    return .success(try Extractor.recover(ids: ids, index: idx, reader: reader, destination: dest, preservePaths: preservePaths) { path, done, _ in
                        Task { @MainActor in
                            session.recover.message = (path as NSString).lastPathComponent
                            if preservePaths { session.recover.progress = Double(done) / max(1, total) }
                        }
                    })
                } catch { return .failure(error) }
            }.value
            switch r {
            case .success(let s): session.recoverSummary = s; session.recover = OperationState()
            case .failure(let e): session.recover = OperationState(); session.recover.error = e is CancellationError ? "Recovery cancelled." : e.localizedDescription
            }
        }
    }
}

struct SummaryView: View {
    let summary: RecoverSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Recovered \(summary.filesRecovered) file\(summary.filesRecovered == 1 ? "" : "s") (\(Format.bytes(summary.bytes)))",
                      systemImage: summary.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.failures.isEmpty ? .green : .orange)
                Button("Show in Finder") { NSWorkspace.shared.open(summary.destination) }.controlSize(.small)
            }
            if !summary.failures.isEmpty || !summary.warnings.isEmpty {
                DisclosureGroup("\(summary.failures.count) failed, \(summary.warnings.count) with warnings") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, f in
                                Text("✗ \(f.path) — \(f.message)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                            ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, w in
                                Text("⚠︎ \(w.path) — \(w.message)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.font(.caption)
            }
        }
    }
}
