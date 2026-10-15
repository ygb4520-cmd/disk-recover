// swift-tools-version:5.9
import PackageDescription

// Windows (phase 1): only the core library and the drcli command-line tool, working on disk-image files.
#if os(Windows)
let package = Package(
    name: "DiskRecover",
    products: [.executable(name: "drcli", targets: ["drcli"])],
    targets: [
        .target(name: "DiskRecoverCore", path: "Sources/DiskRecoverCore"),
        .executableTarget(name: "drcli", dependencies: ["DiskRecoverCore"], path: "Sources/drcli"),
    ]
)
#else
let package = Package(
    name: "DiskRecover",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskRecover", targets: ["DiskRecover"]),
        .executable(name: "drcli", targets: ["drcli"]),
    ],
    targets: [
        // Thin C shim: fd passing over unix sockets, disk ioctls, fcntl wrappers.
        .target(name: "CSupport", path: "Sources/CSupport"),
        // All recovery logic. No UI.
        .target(name: "DiskRecoverCore", dependencies: ["CSupport"], path: "Sources/DiskRecoverCore"),
        // SwiftUI app. The same binary doubles as the root helper (see main.swift).
        .executableTarget(name: "DiskRecover", dependencies: ["DiskRecoverCore"], path: "Sources/DiskRecoverApp"),
        // Command-line front end, mainly for scripted verification.
        .executableTarget(name: "drcli", dependencies: ["DiskRecoverCore"], path: "Sources/drcli"),
        .testTarget(name: "DiskRecoverCoreTests", dependencies: ["DiskRecoverCore"], path: "Tests/DiskRecoverCoreTests"),
    ]
)
#endif
