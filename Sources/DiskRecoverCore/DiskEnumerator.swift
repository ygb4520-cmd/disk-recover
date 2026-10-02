import Foundation

public struct DiskInfo: Identifiable, Hashable {
    public var id: String                 // "disk4"
    public var size: UInt64
    public var mediaName: String
    public var isInternal: Bool
    public var isRemovable: Bool
    public var busProtocol: String
    public var isDiskImage: Bool
    public var isSystemDisk: Bool
    public var content: String            // e.g. GUID_partition_scheme
    public var volumes: [VolumeSummary]
    public var devicePath: String { "/dev/r\(id)" }
    public var blockDevicePath: String { "/dev/\(id)" }
    public var title: String { mediaName.isEmpty ? id : mediaName }

    public struct VolumeSummary: Hashable {
        public var id: String
        public var name: String
        public var size: UInt64
        public var content: String
        public var mountPoint: String?
    }
}

public enum DiskEnumerator {
    public static func listDisks() -> [DiskInfo] {
        guard let list = DestinationCheck.runPlist(["list", "-plist"]),
              let all = list["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var out: [DiskInfo] = []
        for d in all {
            guard let id = d["DeviceIdentifier"] as? String else { continue }
            let info = DestinationCheck.runPlist(["info", "-plist", id]) ?? [:]
            let virtualOrPhysical = info["VirtualOrPhysical"] as? String ?? ""
            let bus = info["BusProtocol"] as? String ?? ""
            let isImage = bus == "Disk Image"
            if virtualOrPhysical == "Virtual" && !isImage { continue }       // synthesized APFS containers
            var vols: [DiskInfo.VolumeSummary] = []
            for p in (d["Partitions"] as? [[String: Any]] ?? []) {
                vols.append(.init(id: p["DeviceIdentifier"] as? String ?? "", name: p["VolumeName"] as? String ?? "",
                                  size: (p["Size"] as? NSNumber)?.uint64Value ?? 0, content: p["Content"] as? String ?? "",
                                  mountPoint: p["MountPoint"] as? String))
            }
            if let apfs = d["APFSVolumes"] as? [[String: Any]] {
                for p in apfs {
                    vols.append(.init(id: p["DeviceIdentifier"] as? String ?? "", name: p["VolumeName"] as? String ?? "",
                                      size: (p["Size"] as? NSNumber)?.uint64Value ?? 0, content: "APFS volume", mountPoint: p["MountPoint"] as? String))
                }
            }
            var disk = DiskInfo(id: id,
                                size: (d["Size"] as? NSNumber)?.uint64Value ?? (info["TotalSize"] as? NSNumber)?.uint64Value ?? 0,
                                mediaName: (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String) ?? "",
                                isInternal: info["Internal"] as? Bool ?? false,
                                isRemovable: (info["RemovableMedia"] as? Bool ?? false) || (info["Removable"] as? Bool ?? false),
                                busProtocol: bus, isDiskImage: isImage, isSystemDisk: false,
                                content: d["Content"] as? String ?? "", volumes: vols)
            disk.isSystemDisk = DestinationCheck.isOnDisk(url: URL(fileURLWithPath: "/"), wholeDisk: id)
            out.append(disk)
        }
        return out
    }

    /// Unmount every volume of a whole disk (required before writing a new partition table).
    public static func unmountDisk(_ id: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["unmountDisk", "/dev/\(id)"]
        let err = Pipe()
        p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DiskError.invalid("Could not unmount \(id): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
