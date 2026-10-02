import SwiftUI
import DiskRecoverCore

struct ToolsView: View {
    @Bindable var session: SourceSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ImageCard(session: session)
                SectorViewer(session: session)
                BackupsCard(session: session)
            }
            .padding(16)
        }
    }
}

struct ImageCard: View {
    @Bindable var session: SourceSession
    @State private var volumeID = "whole"

    var body: some View {
        Card(title: "Create a disk image") {
            Text("Copies the disk (or one partition) into a file. Working on the image is the safest way to recover from a failing disk: unreadable sectors are skipped and recorded instead of stopping the copy, and you can then analyse the image with everything in this app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Copy", selection: $volumeID) {
                ForEach(session.volumeChoices) { Text($0.title).tag($0.id) }
            }.frame(maxWidth: 560).disabled(session.imaging.running)
            HStack {
                if session.imaging.running { Button("Stop") { session.imagingTask?.cancel() } }
                else { Button("Create Image…") { start() }.buttonStyle(.borderedProminent) }
            }
            ProgressRow(state: session.imaging)
            if let r = session.imagingResult { Label(r, systemImage: "checkmark.circle.fill").foregroundStyle(.green).textSelection(.enabled) }
        }
    }

    func start() {
        guard let src = session.source, let c = session.volumeChoices.first(where: { $0.id == volumeID }) ?? session.volumeChoices.last,
              let url = Pick.saveFile(name: "\(session.title.replacingOccurrences(of: " ", with: "-")).img", message: "Save the disk image on a different drive with enough free space.") else { return }
        if let dir = Optional(url.deletingLastPathComponent()), !destinationIsSafe(dir, for: session) { return }
        let range = (c.startLBA * UInt64(src.sectorSize))..<((c.startLBA + c.sectorCount) * UInt64(src.sectorSize))
        session.imaging = OperationState(running: true)
        session.imagingResult = nil
        session.imagingTask = Task {
            let r: Result<ImageResult, Error> = await Task.detached {
                do {
                    return .success(try DiskImager.copy(from: src, range: range, to: url) { p in
                        Task { @MainActor in session.imaging.progress = p }
                    })
                } catch { return .failure(error) }
            }.value
            switch r {
            case .success(let i):
                session.imaging = OperationState()
                session.imagingResult = "Saved \(Format.bytes(i.bytesCopied)) to \(url.lastPathComponent)." +
                    (i.unreadableBytes > 0 ? " \(Format.bytes(i.unreadableBytes)) could not be read and were filled with zeros." : " Every sector was read successfully.")
            case .failure(let e):
                session.imaging = OperationState(); session.imaging.error = e is CancellationError ? "Imaging cancelled; the partial file was removed." : e.localizedDescription
            }
        }
    }
}

struct SectorViewer: View {
    @Bindable var session: SourceSession
    @State private var text = "0"
    @State private var dump = ""
    @State private var kind = ""

    var body: some View {
        Card(title: "Sector viewer") {
            HStack {
                Text("Sector").foregroundStyle(.secondary)
                TextField("LBA", text: $text).textFieldStyle(.roundedBorder).frame(width: 140).onSubmit { go() }
                Button("Go") { go() }
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                Button("Last sector") { session.sectorLBA = (session.source?.sectorCount ?? 1) - 1; text = "\(session.sectorLBA)"; load() }
                Spacer()
                if !kind.isEmpty { Badge(text: kind, color: .accentColor) }
            }
            Text(dump).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { load() }
    }

    func go() { session.sectorLBA = UInt64(text.trimmingCharacters(in: .whitespaces)) ?? 0; load() }
    func step(_ d: Int) {
        let max = (session.source?.sectorCount ?? 1) - 1
        let n = Int64(session.sectorLBA) + Int64(d)
        session.sectorLBA = UInt64(Swift.max(0, Swift.min(Int64(max), n)))
        text = "\(session.sectorLBA)"; load()
    }

    func load() {
        guard let src = session.source else { return }
        guard let d = try? src.read(offset: session.sectorLBA * UInt64(src.sectorSize), length: 512) else { dump = "Cannot read this sector."; kind = ""; return }
        var lines: [String] = []
        for row in stride(from: 0, to: d.count, by: 16) {
            let chunk = d[row..<Swift.min(row + 16, d.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let asc = String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%04X  ", row) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + asc)
        }
        dump = lines.joined(separator: "\n")
        if d.isAllZero { kind = "Empty (all zeros)" }
        else if d.hasPrefix(Array("EFI PART".utf8)) { kind = "GPT header" }
        else if let fs = FilesystemDetector.detect(sector: d + ((try? src.read(offset: (session.sectorLBA + 1) * UInt64(src.sectorSize), length: 4096)) ?? []), sectorSize: src.sectorSize) { kind = "\(fs.displayName) boot sector" }
        else if session.sectorLBA == 0, d.le16(510) == 0xAA55 { kind = "MBR" }
        else if d.hasPrefix(Array("FILE".utf8)) { kind = "NTFS MFT record" }
        else { kind = "" }
    }
}

struct BackupsCard: View {
    @Bindable var session: SourceSession
    @State private var backups: [URL] = []
    @State private var restoring: URL?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Card(title: "Undo: partition table & boot sector backups") {
            Text("Before Disk Recover writes anything it saves the sectors it is about to replace. Restoring a backup puts them back exactly as they were.")
                .font(.callout).foregroundStyle(.secondary)
            if backups.isEmpty { Text("No backups yet.").foregroundStyle(.secondary) }
            ForEach(backups, id: \.self) { b in
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text(b.lastPathComponent).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([b]) }.controlSize(.small)
                    Button("Restore…") { restoring = b }.controlSize(.small).disabled(busy)
                }
            }
            if let m = message { Text(m).font(.callout) }
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Restore this backup to \(session.title)?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            Button("Restore Backup", role: .destructive) { if let r = restoring { Task { await restore(r) } } }
        } message: { Text("The sectors saved in this backup will overwrite the same sectors on this disk.") }
    }

    func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: SectorWriter.backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        backups = urls.filter { $0.pathExtension == "drbackup" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    func restore(_ url: URL) async {
        busy = true; message = nil
        defer { busy = false }
        do {
            let disk = try await session.openForWriting()
            try await Task.detached { try SectorWriter.restore(backup: url, to: disk) }.value
            message = "Backup restored."
            await session.reloadAnalysis()
        } catch HelperError.cancelled { message = "Authorization cancelled; nothing was written." }
        catch { message = error.localizedDescription }
    }
}
