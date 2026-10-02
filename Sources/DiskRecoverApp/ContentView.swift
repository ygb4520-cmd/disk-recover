import SwiftUI
import UniformTypeIdentifiers
import DiskRecoverCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if let s = model.selectedSession {
                SourceView(session: s).id(s.id)
            } else {
                WelcomeView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.refreshDisks() } } label: { Label("Refresh Disks", systemImage: "arrow.clockwise") }
                    .disabled(model.loadingDisks)
                Button { Pick.openImage(model) } label: { Label("Open Disk Image", systemImage: "doc.badge.plus") }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.openImage(url) } }
                }
            }
            return true
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(6).allowsHitTesting(false) } }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Disks") {
                if model.disks.isEmpty && !model.loadingDisks {
                    Text("No disks found").foregroundStyle(.secondary)
                }
                ForEach(model.disks) { d in
                    DiskRow(disk: d)
                        .tag(model.session(for: d).id)
                }
            }
            Section("Disk Images") {
                if model.imageSessions.isEmpty {
                    Text("Drop an image file here, or use Open Disk Image.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.imageSessions) { s in
                    Label(s.title, systemImage: "doc.zipper")
                        .tag(s.id)
                        .contextMenu { Button("Close Image") { model.closeImage(s) } }
                }
            }
        }
        .onChange(of: model.selection) { _, new in
            guard let new else { return }
            if let d = model.disks.first(where: { "disk:\($0.id)" == new }) { model.select(disk: d) }
            else if let s = model.selectedSession, s.state == .closed { Task { await s.open() } }
        }
        .overlay(alignment: .bottom) { if model.loadingDisks { ProgressView().controlSize(.small).padding(8) } }
    }
}

struct DiskRow: View {
    let disk: DiskInfo
    var icon: String { disk.isDiskImage ? "doc.zipper" : disk.isInternal ? "internaldrive" : "externaldrive" }
    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(disk.title).lineLimit(1)
                Text("\(disk.id) · \(Format.bytes(disk.size))" + (disk.busProtocol.isEmpty ? "" : " · \(disk.busProtocol)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if disk.isSystemDisk { Badge(text: "Startup", color: .orange) }
        }
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Disk Recover").font(.largeTitle.bold())
            Text("Select a disk on the left, or open a disk image.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Find lost partitions and rebuild the partition table (MBR or GPT)", systemImage: "magnifyingglass")
                Label("Repair damaged FAT32, exFAT and NTFS boot sectors from their backups", systemImage: "cross.case")
                Label("Browse FAT, exFAT and NTFS volumes and undelete files", systemImage: "arrow.uturn.backward.circle")
                Label("Carve photos, documents, video and more from raw disk space", systemImage: "photo.on.rectangle.angled")
            }
            .font(.callout).padding(.top, 8)
            Text("Everything starts read-only. Nothing is written to a disk unless you explicitly choose to, and the sectors that would change are backed up first.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 460).multilineTextAlignment(.center).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SourceView: View {
    @Bindable var session: SourceSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch session.state {
            case .closed, .opening:
                ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsAccess:
                AccessView(session: session)
            case .failed(let m):
                ContentUnavailableView("Cannot open this disk", systemImage: "xmark.octagon", description: Text(m))
            case .ready:
                VStack(spacing: 0) {
                    Picker("", selection: $session.tab) {
                        ForEach(SourceTab.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 10)
                    Group {
                        switch session.tab {
                        case .partitions: PartitionsView(session: session)
                        case .lost: LostPartitionsView(session: session)
                        case .files: FilesView(session: session)
                        case .photos: PhotoRecoveryView(session: session)
                        case .tools: ToolsView(session: session)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: session.isImage ? "doc.zipper" : (session.diskInfo?.isInternal == true ? "internaldrive" : "externaldrive"))
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.title3.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.state == .ready { Badge(text: "Read-only", color: .green) }
            if session.isSystemDisk { Badge(text: "Startup disk", color: .orange) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    var subtitle: String {
        if let s = session.source { return "\(session.devicePath) · \(Format.bytes(s.size)) · \(s.sectorSize)-byte sectors" }
        if let d = session.diskInfo { return "\(d.devicePath) · \(Format.bytes(d.size))" }
        return session.devicePath
    }
}

struct AccessView: View {
    let session: SourceSession
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Administrator access needed").font(.title2.bold())
            Text("macOS only lets administrators read raw disks. Disk Recover will ask for your password once and use a small helper that can **only read** disks — it cannot change anything unless you later choose an operation that writes.")
                .multilineTextAlignment(.center).frame(maxWidth: 480).foregroundStyle(.secondary)
            Button("Authorize and Open Disk…") { Task { await session.authorizeAndOpen() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if session.isSystemDisk {
                WarningBanner(text: "This is your Mac's startup disk. Recovery on APFS volumes is limited: use Photo Recovery to scan it, and save results to a different drive.")
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
