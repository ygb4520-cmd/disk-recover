import SwiftUI
import DiskRecoverCore

struct PartitionsView: View {
    @Bindable var session: SourceSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let a = session.analysis {
                    summary(a)
                    if !a.issues.isEmpty { issues(a) }
                    table(a)
                } else {
                    ProgressView("Reading partition table…")
                }
            }
            .padding(16)
        }
    }

    func summary(_ a: TableAnalysis) -> some View {
        Card(title: "Partition table") {
            HStack(spacing: 28) {
                stat("Scheme", a.scheme.rawValue)
                stat("Partitions", "\(a.partitions.filter { !$0.isExtendedContainer }.count)")
                stat("Disk size", Format.bytes(a.diskSectors * UInt64(a.sectorSize)))
                stat("Sectors", lbaString(a.diskSectors))
                if let g = a.diskGUID { stat("Disk GUID", g.description) }
            }
            if a.scheme == .none || a.issues.contains(where: { $0.severity == .error }) {
                Button { session.tab = .lost; } label: { Label("Search for lost partitions", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    func issues(_ a: TableAnalysis) -> some View {
        Card(title: "Findings") {
            ForEach(a.issues) { i in
                Label(i.message, systemImage: i.severity == .error ? "xmark.octagon.fill" : i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(i.severity == .error ? .red : i.severity == .warning ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func table(_ a: TableAnalysis) -> some View {
        Card(title: "Partitions") {
            if a.partitions.isEmpty {
                Text("There are no partitions in the table.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        ForEach(["#", "Type", "Filesystem", "Start sector", "End sector", "Size", "Name"], id: \.self) { Text($0).font(.caption.bold()).foregroundStyle(.secondary) }
                        Text("")
                    }
                    Divider().gridCellColumns(8)
                    ForEach(a.partitions.filter { !$0.isExtendedContainer }) { p in
                        let fs = session.partitionFS[p.startLBA]
                        GridRow {
                            Text("\(p.index)")
                            Text(p.typeDescription)
                            if let fs { Text(fs.displayName + (fs.label.map { " “\($0)”" } ?? "")) } else { Text("—").foregroundStyle(.secondary) }
                            Text(lbaString(p.startLBA)).monospacedDigit()
                            Text(lbaString(p.endLBA)).monospacedDigit()
                            Text(Format.bytes(p.byteSize(sectorSize: a.sectorSize)))
                            Text(p.name)
                            HStack {
                                if fs?.kind.supportsFileRecovery == true {
                                    Button("Browse Files") {
                                        session.selectedVolumeID = "t\(p.startLBA)"; session.fsState = .idle; session.tab = .files
                                    }
                                }
                                Button("Find Photos") { session.carveVolumeID = "t\(p.startLBA)"; session.tab = .photos }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
