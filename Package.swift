// swift-tools-version:5.9
import PackageDescription

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
