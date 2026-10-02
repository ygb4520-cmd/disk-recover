import SwiftUI
import UniformTypeIdentifiers
import DiskRecoverCore

struct DiskRecoverApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Disk Recover") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1020, minHeight: 640)
                .task {
                    await model.refreshDisks()
                    if DebugDriver.enabled { await DebugDriver.run(model: model) }
                }
                .onOpenURL { model.openImage($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Disk Image…") { Pick.openImage(model) }.keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Disks") { Task { await model.refreshDisks() } }.keyboardShortcut("r")
            }
        }
    }
}

enum Pick {
    @MainActor static func openImage(_ model: AppModel) {
        let p = NSOpenPanel()
        p.message = "Choose a disk image (.img, .dd, .raw, .iso, or any raw dump) to analyse"
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { model.openImage(u) }
    }

    @MainActor static func folder(message: String, prompt: String = "Choose") -> URL? {
        let p = NSOpenPanel()
        p.message = message; p.prompt = prompt
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor static func saveFile(name: String, message: String) -> URL? {
        let p = NSSavePanel()
        p.message = message; p.nameFieldStringValue = name; p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }
}

// MARK: shared components

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = title { Text(t).font(.headline) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ProgressRow: View {
    let state: OperationState
    var onCancel: (() -> Void)?
    var body: some View {
        if state.running {
            HStack(spacing: 10) {
                ProgressView(value: state.progress).frame(maxWidth: .infinity)
                Text("\(Int(state.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                if !state.message.isEmpty { Text(state.message).foregroundStyle(.secondary).lineLimit(1) }
                if let c = onCancel { Button("Cancel", action: c) }
            }
        } else if let e = state.error {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
        }
    }
}

struct WarningBanner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension UInt64 {
    func sizeString() -> String { Format.bytes(self) }
}

func lbaString(_ v: UInt64) -> String { v.formatted(.number.grouping(.never)) }
