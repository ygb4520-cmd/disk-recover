import SwiftUI
import DiskRecoverCore

struct PhotoRecoveryView: View {
    @Bindable var session: SourceSession

    var choices: [VolumeChoice] { session.volumeChoices }
    var chosen: VolumeChoice? { choices.first { $0.id == session.carveVolumeID } ?? choices.last }
    var canUseFreeSpace: Bool { chosen?.fs?.kind.supportsFileRecovery == true }

    var body: some View {
        content.onReceive(NotificationCenter.default.publisher(for: .debugStartCarve)) { _ in if DebugDriver.enabled { start() } }
    }

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Photo Recovery finds files by their contents instead of by the filesystem, so it works even when the filesystem is damaged, reformatted or unsupported. File names and folders are not preserved — files are saved by type as f<sector>.<ext>.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                whereCard
                typesCard
                destinationCard
                runCard
                if !session.carveFiles.isEmpty { resultsCard }
            }
            .padding(16)
        }
    }

    var whereCard: some View {
        Card(title: "1. Where to look") {
            Picker("Scan", selection: Binding(get: { chosen?.id ?? "" }, set: { session.carveVolumeID = $0 })) {
                ForEach(choices) { Text($0.title).tag($0.id) }
            }
            .frame(maxWidth: 560).disabled(session.carve.running)
            Toggle("Only unallocated space (much faster; best for files you deleted)", isOn: $session.carveFreeSpaceOnly)
                .disabled(!canUseFreeSpace || session.carve.running)
            if !canUseFreeSpace {
                Text("Unallocated-space scans need a readable FAT, exFAT or NTFS volume. This area will be scanned in full.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Check every sector (slower). Off = check every 4 KiB.", isOn: $session.carveFineAlignment)
                .disabled(session.carveFreeSpaceOnly || session.carve.running)
        }
    }

    var typesCard: some View {
        Card(title: "2. File types") {
            HStack {
                Button("Select All") { session.carveFamilies = Set(CarveFormats.families.map { $0.id }) }
                Button("Select None") { session.carveFamilies = [] }
            }.controlSize(.small)
            ForEach(Category.allCases, id: \.self) { cat in
                let fams = CarveFormats.families.filter { $0.category == cat }
                if !fams.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cat.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 4) {
                            ForEach(fams) { f in
                                Toggle(isOn: Binding(get: { session.carveFamilies.contains(f.id) },
                                                     set: { on in if on { session.carveFamilies.insert(f.id) } else { session.carveFamilies.remove(f.id) } })) {
                                    Text(f.title) + Text("  \(f.extensions)").foregroundStyle(.secondary).font(.caption)
                                }.toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
        }
        .disabled(session.carve.running)
    }

    var destinationCard: some View {
        Card(title: "3. Save recovered files to") {
            HStack {
                Button("Choose Folder…") {
                    if let u = Pick.folder(message: "Choose a folder on a different drive than the one you're recovering from.", prompt: "Choose"), destinationIsSafe(u, for: session) { session.carveDestination = u }
                }
                Text(session.carveDestination?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    var runCard: some View {
        Card(title: "4. Scan") {
            HStack {
                if session.carve.running {
                    Button("Stop") { session.carveTask?.cancel() }
                } else {
                    Button { start() } label: { Label("Start Recovery Scan", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.carveDestination == nil || session.carveFamilies.isEmpty || chosen == nil)
                }
            }
            if session.carve.running {
                let p = session.carveProgress
                ProgressView(value: p.fraction)
                HStack(spacing: 16) {
                    Text("\(Int(p.fraction * 100))%").monospacedDigit()
                    Text("\(Format.bytes(p.scannedBytes)) of \(Format.bytes(p.totalBytes))")
                    if session.carveSpeed > 0 { Text("\(Format.bytes(UInt64(session.carveSpeed)))/s") }
                    Text("\(p.filesFound) file\(p.filesFound == 1 ? "" : "s") found").bold()
                }.font(.callout).foregroundStyle(.secondary)
            } else if let e = session.carve.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if !session.carve.message.isEmpty {
                Label(session.carve.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    var resultsCard: some View {
        Card(title: "Recovered files") {
            let p = session.carveProgress
            HStack {
                ForEach(p.perFamily.sorted { $0.key < $1.key }, id: \.key) { k, v in Badge(text: "\(k): \(v)", color: .accentColor) }
                Spacer()
                if let d = session.carveDestination { Button("Show in Finder") { NSWorkspace.shared.open(d) } }
            }
            if p.partialFiles > 0 {
                Text("\(p.partialFiles) file\(p.partialFiles == 1 ? " is" : "s are") marked _partial: the start was found but the rest looked damaged or overwritten, so they may open with errors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Table(session.carveFiles.suffix(300).reversed()) {
                TableColumn("File") { f in Text(f.url.lastPathComponent).textSelection(.enabled) }
                TableColumn("Type") { f in Text(f.ext) }.width(60)
                TableColumn("Size") { f in Text(Format.bytes(f.length)) }.width(90)
                TableColumn("Status") { f in if f.partial { Badge(text: "Partial", color: .orange) } else { Badge(text: "Complete", color: .green) } }.width(90)
                TableColumn("") { f in Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }.controlSize(.small) }.width(70)
            }
            .frame(height: 260)
        }
    }

    func start() {
        guard let c = chosen, let vol = session.volume(for: c), let src = session.source, let dest = session.carveDestination else { return }
        let families = session.carveFamilies
        let freeOnly = session.carveFreeSpaceOnly && canUseFreeSpace
        let align = session.carveFineAlignment ? src.sectorSize : max(4096, src.sectorSize)
        session.carve = OperationState(running: true)
        session.carveProgress = CarveProgress()
        session.carveFiles = []
        session.carveSpeed = 0
        let startTime = Date()
        let sectorSize = src.sectorSize
        session.carveTask = Task {
            let outcome: Result<CarveProgress, Error> = await Task.detached {
                do {
                    var ranges = [vol.offset..<(vol.offset + vol.length)]
                    var alignment = align
                    if freeOnly {
                        let fs = try FileSystemFactory.open(volume: vol, sectorSize: sectorSize)
                        ranges = try fs.freeRanges()
                        alignment = max(fs.info.clusterSize, sectorSize)
                    }
                    let carver = Carver(source: src, options: CarveOptions(families: families, ranges: ranges, alignment: alignment, destination: dest))
                    let p = try carver.run(progress: { prog in
                        Task { @MainActor in
                            session.carveProgress = prog
                            let t = Date().timeIntervalSince(startTime)
                            if t > 0.5 { session.carveSpeed = Double(prog.scannedBytes) / t }
                        }
                    }, onFile: { f in
                        Task { @MainActor in
                            session.carveFiles.append(f)
                            if session.carveFiles.count > 2000 { session.carveFiles.removeFirst(500) }
                        }
                    })
                    return .success(p)
                } catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let p):
                session.carveProgress = p
                session.carve = OperationState()
                session.carve.message = p.filesFound == 0 ? "Scan finished: no recognisable files were found." : "Scan finished: \(p.filesFound) files saved."
            case .failure(let e):
                session.carve = OperationState()
                session.carve.error = e is CancellationError ? "Scan stopped. Files found so far were kept." : e.localizedDescription
            }
        }
    }
}
