import SwiftUI
import DiskRecoverCore

// The same binary doubles as the root helper that hands raw-disk file descriptors to the app
// (see PrivilegedHelper.swift). When launched with --helper it never starts the UI.
if CommandLine.arguments.contains("--helper") {
    HelperServer.run(arguments: CommandLine.arguments)
}
DiskRecoverApp.main()
