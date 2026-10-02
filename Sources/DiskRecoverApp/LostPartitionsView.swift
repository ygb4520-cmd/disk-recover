import SwiftUI
import DiskRecoverCore

struct LostPartitionsView: View {
    @Bindable var session: SourceSession
    @State private var showWrite = false
    @State private var repairTarget: FoundPartition?

    var conflictIDs: Set<UUID> {
        var out = Set<UUID>()
        let sel = session.found.filter { $0.selected }
        for i in 0..<sel.count {
            for j in (i + 1)..<Swift.max(i + 1, sel.count) where sel[i].startLBA <= sel[j].endLBA && sel[j].startLBA <= sel[i].endLBA {
                out.insert(sel[i].id); out.insert(sel[j].id)
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    results
                }
                .padding(16)
            }
            if !session.found.isEmpty { actionBar }
        }
        .sheet(isPresented: $showWrite) {
            WriteTableSheet(session: session, partitions: session.found.filter { $0.selected })
        }
        .sheet(item: $repairTarget) { f in RepairBootSheet(session: session, partition: f) }
    }

    var controls: some View {
        Card(title: "Search the whole disk for filesystems") {
            Text("Like TestDisk's Analyse + Search: every sector is checked for the signature of a FAT, exFAT, NTFS, ext, HFS+ or APFS volume. Where a volume's first sector has been destroyed, its backup boot sector is used to locate it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Mode", selection: $session.searchMode) {
                ForEach(SearchModeChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 360).disabled(session.search.running)
            Text(session.searchMode == .quick
                 ? "Quick checks the places partitions normally start (1 MiB and cylinder boundaries) and the sectors that follow each partition it finds. It takes seconds."
                 : "Deep reads the entire disk, so it can find partitions at unusual positions and via backup boot sectors. Expect it to take as long as copying the disk.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if session.search.running {
                    Button("Stop") { session.cancelSearch() }
                } else {
                    Button { session.runSearch() } label: { Label(session.searchRan ? "Search Again" : "Start Search", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                }
            }
            ProgressRow(state: session.search)
        }
    }

    @ViewBuilder var results: some View {
        if session.searchRan && session.found.isEmpty {
            ContentUnavailableView("No filesystems found", systemImage: "questionmark.folder",
                                   description: Text(session.searchMode == .quick ? "Try a Deep search. If the disk held APFS, ext or other unsupported data, or was overwritten or encrypted, nothing may be found here — Photo Recovery can still carve files from raw space." : "Nothing recognisable was found on this disk. Photo Recovery can still carve individual files from raw space."))
        } else if !session.found.isEmpty {
            Card(title: "Found \(session.found.count) filesystem\(session.found.count == 1 ? "" : "s")") {
                Text("Tick the partitions that belong in the new partition table. Overlapping hits can't be chosen together; the most likely set is pre-selected.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($session.found) { $f in
                    FoundRow(found: $f, sectorSize: session.sectorSize, conflict: conflictIDs.contains(f.id),
                             browse: {
                                session.selectedVolumeID = "f\(f.startLBA)"; session.fsState = .idle; session.tab = .files
                             },
                             repair: { repairTarget = f })
                    Divider()
                }
            }
        }
    }

    var actionBar: some View {
        HStack {
            let n = session.found.filter { $0.selected }.count
            if !conflictIDs.isEmpty { Label("Selected partitions overlap", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            else { Text("\(n) partition\(n == 1 ? "" : "s") selected").foregroundStyle(.secondary) }
            Spacer()
            Button { showWrite = true } label: { Label("Write Partition Table…", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent)
                .disabled(n == 0 || !conflictIDs.isEmpty || session.isSystemDisk)
        }
        .padding(12).background(.bar)
    }
}

struct FoundRow: View {
    @Binding var found: FoundPartition
    let sectorSize: Int
    let conflict: Bool
    let browse: () -> Void
    let repair: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $found.selected).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(found.fs.displayName).font(.headline)
                    if let l = found.fs.label { Text("“\(l)”").foregroundStyle(.secondary) }
                    Text(Format.bytes(found.sectorCount * UInt64(sectorSize))).foregroundStyle(.secondary)
                    if found.matchesCurrentTable { Badge(text: "In current table", color: .green) }
                    if found.viaBackup { Badge(text: "Boot sector damaged", color: .orange) }
                    if found.confidence < 60 { Badge(text: "Low confidence", color: .secondary) }
                    if conflict { Badge(text: "Overlaps", color: .red) }
                }
                Text("Sectors \(lbaString(found.startLBA)) – \(lbaString(found.endLBA))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if !found.note.isEmpty { Text(found.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            HStack {
                if found.fs.kind.supportsFileRecovery { Button("Browse Files", action: browse) }
                if found.viaBackup, [.fat32, .exfat, .ntfs].contains(found.fs.kind) { Button("Repair Boot Sector…", action: repair) }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Write partition table

struct WriteTableSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SourceSession
    let partitions: [FoundPartition]
    @State private var scheme: TableWriter.Scheme = .mbr
    @State private var acknowledged = false
    @State private var busy = false
    @State private var error: String?
    @State private var backupURL: URL?
    @State private var planned: [PlannedPartition] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write partition table").font(.title2.bold())
            if let b = backupURL {
                Label("The new partition table was written.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("The original sectors were saved first, so this can be undone from Tools ▸ Backups.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b]) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("This replaces the partition table on **\(session.title)** with the \(partitions.count) partition\(partitions.count == 1 ? "" : "s") you selected. Your files are not touched — only the table that says where each partition lives.")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Table type", selection: $scheme) {
                    Text("MBR").tag(TableWriter.Scheme.mbr)
                    Text("GPT").tag(TableWriter.Scheme.gpt)
                }
                .pickerStyle(.segmented).frame(maxWidth: 240)
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(planned.sorted { $0.startLBA < $1.startLBA }) { p in
                            let f = partitions.first { $0.startLBA == p.startLBA }
                            Text("\(f?.fs.displayName ?? "?") · sectors \(lbaString(p.startLBA)) – \(lbaString(p.endLBA)) · \(Format.bytes(p.sectorCount * UInt64(session.sectorSize)))")
                                .font(.callout.monospacedDigit())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !session.isImage {
                    WarningBanner(text: "This is a physical disk. You will be asked for your administrator password and every volume on it will be unmounted first.")
                }
                Toggle("I understand this changes the disk's partition table. The original sectors are backed up first.", isOn: $acknowledged)
                if let e = error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Write Table") { Task { await write() } }
                        .keyboardShortcut(.defaultAction).disabled(!acknowledged || busy)
                }
            }
        }
        .padding(20).frame(width: 560)
        .onAppear { setup() }
    }

    func setup() {
        guard let a = session.analysis else { return }
        planned = partitions.map { PlannedPartition(found: $0, existing: a.partitions) }
        scheme = TableWriter.recommendedScheme(analysis: a, partitions: planned, diskSectors: session.source?.sectorCount ?? 0)
    }

    func write() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let disk = try await session.openForWriting()
            guard let a = session.analysis else { return }
            let writes = try TableWriter.plan(scheme: scheme, partitions: planned, disk: disk, existing: a)
            let url = try await Task.detached { try SectorWriter.apply(writes, to: disk, reason: "Write partition table from Disk Recover") }.value
            backupURL = url
            await session.reloadAnalysis()
            for i in session.found.indices {
                session.found[i].matchesCurrentTable = session.analysis?.partitions.contains { $0.startLBA == session.found[i].startLBA } ?? false
            }
        } catch HelperError.cancelled {
            error = "Authorization was cancelled; nothing was written."
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Repair boot sector

struct RepairBootSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SourceSession
    let partition: FoundPartition
    @State private var status: BootRepair.Status?
    @State private var busy = false
    @State private var error: String?
    @State private var done: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repair boot sector").font(.title2.bold())
            Text("\(partition.fs.displayName) · sectors \(lbaString(partition.startLBA)) – \(lbaString(partition.endLBA))").foregroundStyle(.secondary)
            if let s = status { Label(s.summary, systemImage: s.primaryOK ? "checkmark.circle" : "exclamationmark.triangle.fill") }
            else { ProgressView() }
            if let d = done {
                Label("Boot sector restored.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Reveal Backup of Old Sectors") { NSWorkspace.shared.activateFileViewerSelecting([d]) }
            }
            if let e = error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
            if !session.isImage && done == nil, status?.backupOK == true, status?.primaryOK == false {
                WarningBanner(text: "This is a physical disk. You'll be asked for your administrator password and its volumes will be unmounted.")
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(done == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if done == nil {
                    Button("Restore From Backup") { Task { await repair() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || !(status?.supported == true && status?.backupOK == true && status?.primaryOK == false))
                }
            }
        }
        .padding(20).frame(width: 520)
        .task {
            guard let src = session.source else { return }
            let p = partition
            status = await Task.detached { BootRepair.assess(src, start: p.startLBA, fs: p.fs) }.value
        }
    }

    func repair() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let disk = try await session.openForWriting()
            let p = partition
            let url: URL = try await Task.detached {
                let w = try BootRepair.plan(disk, start: p.startLBA, fs: p.fs, backupToPrimary: true)
                return try SectorWriter.apply(w, to: disk, reason: "Repair boot sector")
            }.value
            done = url
            if let src = session.source {
                let p2 = partition
                status = await Task.detached { BootRepair.assess(src, start: p2.startLBA, fs: p2.fs) }.value
            }
            await session.reloadAnalysis()
        } catch HelperError.cancelled {
            error = "Authorization was cancelled; nothing was written."
        } catch { self.error = error.localizedDescription }
    }
}
