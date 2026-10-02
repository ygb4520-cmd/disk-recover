import SwiftUI
import DiskRecoverCore

/// Scripted UI exercise for development, enabled only by environment variables (never active in normal use):
///   DISKRECOVER_DEBUG_DIR=<dir>      where snapshots are written
///   DISKRECOVER_DEBUG_SCRIPT=<cmds>  semicolon-separated: image=<path>, tab=<name>, search=quick|deep, volume=<id>, load,
///                                    carve=<destDir>, wait=<seconds>, shot=<name>, quit
/// Launch with `open -g -n --env ... DiskRecover.app` so no window steals focus. Snapshots render the window's own
/// view hierarchy, so no screen-recording permission is needed.
@MainActor
enum DebugDriver {
    static var enabled: Bool { ProcessInfo.processInfo.environment["DISKRECOVER_DEBUG_SCRIPT"] != nil }

    static func run(model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let script = env["DISKRECOVER_DEBUG_SCRIPT"] else { return }
        let dir = URL(fileURLWithPath: env["DISKRECOVER_DEBUG_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("driver.log"), atomically: true, encoding: .utf8) }
        try? await Task.sleep(for: .seconds(1))
        if let w = NSApp.windows.first { w.setContentSize(NSSize(width: 1280, height: 860)) }

        for raw in script.split(separator: ";") {
            let cmd = raw.trimmingCharacters(in: .whitespaces)
            let (name, arg) = { () -> (String, String) in
                guard let i = cmd.firstIndex(of: "=") else { return (cmd, "") }
                return (String(cmd[..<i]), String(cmd[cmd.index(after: i)...]))
            }()
            note("> \(cmd)")
            switch name {
            case "image":
                model.openImage(URL(fileURLWithPath: arg))
                for _ in 0..<100 { if model.selectedSession?.state == .ready { break }; try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(600))
            case "tab":
                if let t = SourceTab.allCases.first(where: { $0.rawValue.lowercased().contains(arg.lowercased()) }) { model.selectedSession?.tab = t }
                try? await Task.sleep(for: .milliseconds(500))
            case "search":
                guard let s = model.selectedSession else { break }
                s.searchMode = arg == "deep" ? .deep : .quick
                s.runSearch()
                for _ in 0..<600 { if !s.search.running { break }; try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(400))
            case "volume":
                model.selectedSession?.selectedVolumeID = arg
                model.selectedSession?.carveVolumeID = arg
            case "load":
                // The Files tab owns its loader; simulate the button by flipping to idle then asking the view via notification.
                NotificationCenter.default.post(name: .debugLoadFiles, object: nil)
                for _ in 0..<300 { try? await Task.sleep(for: .milliseconds(100)); if model.selectedSession?.fsState == .ready { break } }
                try? await Task.sleep(for: .milliseconds(600))
            case "carve":
                guard let s = model.selectedSession else { break }
                s.carveDestination = URL(fileURLWithPath: arg)
                NotificationCenter.default.post(name: .debugStartCarve, object: nil)
                try? await Task.sleep(for: .milliseconds(300))
                for _ in 0..<600 { if !s.carve.running { break }; try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(600))
            case "wait":
                try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "shot":
                snapshot(dir.appendingPathComponent("\(arg).png"))
            case "quit":
                NSApp.terminate(nil)
            default: note("unknown command \(name)")
            }
        }
        note("done")
    }

    static func snapshot(_ url: URL) {
        guard let view = NSApp.windows.first(where: { $0.contentView != nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension Notification.Name {
    static let debugLoadFiles = Notification.Name("DiskRecoverDebugLoadFiles")
    static let debugStartCarve = Notification.Name("DiskRecoverDebugStartCarve")
}
