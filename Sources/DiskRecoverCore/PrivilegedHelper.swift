import Foundation
import CSupport

/// Raw disks are root-only on macOS. Instead of running the whole app as root, the app launches a tiny
/// helper (this same binary, started with `--helper`) through the standard administrator-password dialog.
/// The helper opens the requested /dev/rdiskN and passes the open file descriptor back over a Unix socket,
/// so the app itself never runs with elevated privileges. The helper is read-only unless `--write` is given.
public enum HelperProtocol {
    static let requestSize = 1056
    static let replySize = 8
    static let tokenLength = 32
}

public enum HelperServer {
    /// Called from the binary's `main` when started as `<exe> --helper <socket> <token> <uid> [--write]`. Never returns.
    public static func run(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--helper"), arguments.count >= i + 4 else { exit(64) }
        let socketPath = arguments[i + 1], token = arguments[i + 2]
        guard let uid = UInt32(arguments[i + 3]) else { exit(64) }
        let allowWrite = arguments.contains("--write")
        let sock = cs_unix_connect(socketPath)
        guard sock >= 0 else { exit(1) }
        var peer: UInt32 = 0
        guard cs_peer_uid(sock, &peer) == 0, peer == uid else { exit(2) }
        let isRoot = geteuid() == 0
        let pattern = try! NSRegularExpression(pattern: "^/dev/r?disk[0-9]+(s[0-9]+)?$")

        while true {
            var req = [UInt8](repeating: 0, count: HelperProtocol.requestSize)
            var got = 0
            let total = req.count
            while got < total {
                let n = req.withUnsafeMutableBytes { read(sock, $0.baseAddress!.advanced(by: got), total - got) }
                if n <= 0 { exit(0) }          // the app went away
                got += n
            }
            let tok = String(decoding: req[0..<HelperProtocol.tokenLength], as: UTF8.self)
            let mode = req[HelperProtocol.tokenLength]
            let pathBytes = req[(HelperProtocol.tokenLength + 1)...].prefix { $0 != 0 }
            let path = String(decoding: pathBytes, as: UTF8.self)

            var reply = [UInt8](repeating: 0, count: HelperProtocol.replySize)
            var fd: Int32 = -1
            func fail(_ e: Int32) { reply[0] = 1; reply.put32le(4, UInt32(bitPattern: e)) }

            if tok != token { fail(EPERM) }
            else if mode == UInt8(ascii: "W") && !allowWrite { fail(EACCES) }
            else if isRoot && pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) == nil { fail(EINVAL) }
            else {
                fd = open(path, mode == UInt8(ascii: "W") ? O_RDWR : O_RDONLY)
                if fd < 0 { fail(errno) }
            }
            _ = cs_send_fd(sock, fd, reply, reply.count)
            if fd >= 0 { close(fd) }
        }
    }
}

public enum HelperError: LocalizedError {
    case cancelled
    case failed(String)
    case notConnected
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Administrator authorization was cancelled."
        case .failed(let m): return m
        case .notConnected: return "The privileged helper is not running."
        }
    }
}

public final class HelperClient: @unchecked Sendable {
    public let allowsWrite: Bool
    private var conn: Int32 = -1
    private let token: String
    private let lock = NSLock()
    private var tempDir: URL?

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return conn >= 0 }

    public init(allowWrite: Bool) {
        self.allowsWrite = allowWrite
        self.token = (0..<HelperProtocol.tokenLength / 2).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    deinit { disconnect() }

    public func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if conn >= 0 { close(conn); conn = -1 }
        if let d = tempDir { try? FileManager.default.removeItem(at: d); tempDir = nil }
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Show the system administrator dialog and start the helper. `executable` is this app's own binary.
    public func authorize(executable: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskRecover-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        tempDir = dir
        let sockPath = dir.appendingPathComponent("h.sock").path
        let listener = cs_unix_listen(sockPath)
        guard listener >= 0 else { throw HelperError.failed("Cannot create the helper socket: \(String(cString: strerror(errno)))") }
        defer { close(listener) }

        var cmd = "\(Self.shellQuote(executable)) --helper \(Self.shellQuote(sockPath)) \(token) \(getuid())"
        if allowsWrite { cmd += " --write" }
        cmd += " >/dev/null 2>&1 &"
        let script = "do shell script \(Self.appleScriptString(cmd)) with administrator privileges"

        let status: Int32 = try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = Pipe()
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if msg.contains("-128") || msg.lowercased().contains("canceled") { return -128 }
                throw HelperError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return 0
        }.value
        if status == -128 { throw HelperError.cancelled }

        let c = await Task.detached { cs_unix_accept(listener, 15_000) }.value
        guard c >= 0 else { throw HelperError.failed("The privileged helper did not start.") }
        setConnection(c)
    }

    private func setConnection(_ c: Int32) { lock.lock(); conn = c; lock.unlock() }

    /// Starts the helper as an ordinary child process (no administrator prompt). The protocol is identical;
    /// without root the helper can only open what the user could open anyway. Used by tests.
    public func launchUnprivilegedForTesting(executable: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskRecover-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        tempDir = dir
        let sockPath = dir.appendingPathComponent("h.sock").path
        let listener = cs_unix_listen(sockPath)
        guard listener >= 0 else { throw HelperError.failed("socket") }
        defer { close(listener) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--helper", sockPath, token, String(getuid())] + (allowsWrite ? ["--write"] : [])
        try p.run()
        let c = cs_unix_accept(listener, 10_000)
        guard c >= 0 else { throw HelperError.failed("The helper did not connect.") }
        setConnection(c)
    }

    /// Ask the helper to open a raw device and return a DiskSource around the descriptor it sends back.
    public func open(path: String, writable: Bool) throws -> DiskSource {
        lock.lock(); defer { lock.unlock() }
        guard conn >= 0 else { throw HelperError.notConnected }
        var req = [UInt8](repeating: 0, count: HelperProtocol.requestSize)
        req.put(0, Array(token.utf8))
        req[HelperProtocol.tokenLength] = UInt8(ascii: writable ? "W" : "R")
        let pb = Array(path.utf8.prefix(1023))
        req.put(HelperProtocol.tokenLength + 1, pb)
        var sent = 0
        while sent < req.count {
            let n = req.withUnsafeBytes { write(conn, $0.baseAddress!.advanced(by: sent), req.count - sent) }
            if n <= 0 { throw HelperError.notConnected }
            sent += n
        }
        var reply = [UInt8](repeating: 0, count: HelperProtocol.replySize)
        var fd: Int32 = -1
        let n = cs_recv_fd(conn, &fd, &reply, reply.count)
        guard n == HelperProtocol.replySize else { throw HelperError.notConnected }
        if reply[0] != 0 {
            throw DiskError.openFailed(path: path, errno: Int32(bitPattern: reply.le32(4)))
        }
        guard fd >= 0 else { throw HelperError.failed("The helper did not return a disk handle.") }
        return try DiskSource(fd: fd, path: path, writable: writable)
    }
}
