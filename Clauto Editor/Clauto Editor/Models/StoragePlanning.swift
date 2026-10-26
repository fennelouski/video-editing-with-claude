import Foundation

enum StorageRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case edits, originals, cache, exports, backups
    var id: String { rawValue }
    var label: String {
        switch self {
        case .edits: "Edit workspace"
        case .originals: "Original media copies"
        case .cache: "Proxies & recoverable cache"
        case .exports: "Export delivery copies"
        case .backups: "Project backups"
        }
    }
    var folderName: String { switch self { case .edits: "Projects"; case .originals: "Originals"; case .cache: "Cache"; case .exports: "Exports"; case .backups: "Backups" } }
}

struct StorageVolume: Codable, Equatable, Identifiable, Sendable {
    enum Medium: String, Codable, Sendable { case ssd, rotational, unknown }
    var id: String
    var name: String
    var path: String
    var capacityGroup: String
    var filesystem: String
    var totalBytes: Int64
    /// Conservative current available blocks. Purgeable capacity is separate.
    var availableBytes: Int64
    var importantUsageBytes: Int64?
    var local: Bool
    var internalDevice: Bool
    var medium: Medium
    var writable: Bool
    var available: Bool
    var observed: Date
    var performance: StoragePerformance
}

struct StoragePerformance: Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable { case estimated, measured, unknown }
    var basis: Basis
    var readMBps: Double?
    var writeMBps: Double?
    var explanation: String
    var measuredAt: Date?
    var label: String {
        switch basis {
        case .measured: "Measured sample"
        case .estimated: "Estimated; no speed test run"
        case .unknown: "Performance unknown"
        }
    }
    static func estimate(local: Bool, medium: StorageVolume.Medium) -> Self {
        .init(basis: .estimated, readMBps: nil, writeMBps: nil,
            explanation: local ? (medium == .ssd ? "Observed SSD; local random access usually suits active edits and proxies. Sustained throughput has not been measured." : "Local device; media type or sustained performance is unverified. Prefer it for active state only with enough headroom.") : "Network volume; connection speed, server load and latency are unmeasured. Suitable media/archive use still needs a playback check.", measuredAt: nil)
    }
}

struct StorageWorkload: Codable, Equatable, Sendable {
    static let gib: Int64 = 1_073_741_824
    var originalsGiB: Double = 50
    var footageHours: Double = 2
    var finishedMinutes: Double = 15
    var proxyMbps: Double = 12
    var exportMbps: Double = 100
    var reserveFraction: Double = 0.10
    var minimumReserveGiB: Double = 20
    func validate() throws {
        guard [originalsGiB,footageHours,finishedMinutes,proxyMbps,exportMbps,reserveFraction,minimumReserveGiB].allSatisfy(\.isFinite),
              (0...100_000).contains(originalsGiB), (0...10_000).contains(footageHours), (0...100_000).contains(finishedMinutes),
              (1...500).contains(proxyMbps), (1...5000).contains(exportMbps), (0.01...0.50).contains(reserveFraction),
              (1...10_000).contains(minimumReserveGiB) else { throw WorkflowFailure.invalid("Enter finite, nonnegative footprint estimates and a reserve from 1% to 50%.") }
    }
    func bytes(for role: StorageRole) -> Int64 {
        guard [originalsGiB,footageHours,finishedMinutes,proxyMbps,exportMbps].allSatisfy(\.isFinite) else { return 0 }
        let proxy = footageHours * 3600 * proxyMbps * 1_000_000 / 8
        let export = finishedMinutes * 60 * exportMbps * 1_000_000 / 8
        let edits = max(2 * Double(Self.gib), export * 2)
        let value: Double = switch role {
        case .edits: edits
        case .originals: originalsGiB * Double(Self.gib)
        case .cache: max(Double(Self.gib), proxy * 1.5)
        case .exports: export * 2
        case .backups: edits + export * 2
        }
        return Int64(min(max(0,value),Double(Int64.max / 4)))
    }
    func reserve(on volume: StorageVolume) -> Int64 {
        guard reserveFraction.isFinite,minimumReserveGiB.isFinite else { return Int64.max / 4 }
        return Int64(min(Double(Int64.max / 4), max(minimumReserveGiB * Double(Self.gib), Double(max(0,volume.totalBytes)) * reserveFraction)))
    }
}

struct StorageAdvice: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case localRules, connectedClaude }
    var source: Source
    var choices: [StorageRole: String]
    var explanation: String
    var warnings: [String]
    var responseSHA256: String?
}

enum StorageRecommendation {
    static func local(volumes: [StorageVolume], workload: StorageWorkload) throws -> StorageAdvice {
        try workload.validate()
        var choices: [StorageRole:String] = [:], allocated: [String:Int64] = [:], warnings: [String] = []
        for role in StorageRole.allCases {
        let ranked = volumes.filter { $0.available && $0.writable && $0.totalBytes > 0 && $0.availableBytes >= 0 }.sorted {
                let a = score($0,role: role,chosen: choices,volumes: volumes), b = score($1,role: role,chosen: choices,volumes: volumes)
                return a == b ? $0.id < $1.id : a > b
            }
            let chosen = ranked.first { volume in
                volume.availableBytes - (allocated[volume.capacityGroup] ?? 0) - workload.bytes(for: role) >= workload.reserve(on: volume)
            }
            guard let chosen else { warnings.append("No available drive can fit \(role.label.lowercased()) and the reserve. Reduce the estimate or choose another drive."); continue }
            choices[role] = chosen.id; allocated[chosen.capacityGroup,default: 0] += workload.bytes(for: role)
            if !chosen.local && [.edits,.cache].contains(role) { warnings.append("\(role.label) uses a network drive because local headroom is insufficient. Latency is unmeasured; disconnecting pauses new work.") }
        }
        if let backup = choices[.backups].flatMap({ id in volumes.first { $0.id == id } }),
           [StorageRole.edits,.originals].compactMap({ choices[$0] }).contains(where: { id in volumes.first { $0.id == id }?.capacityGroup == backup.capacityGroup }) {
            warnings.append("Backup and working media share a storage device/group. This is an additional copy, not an independent disaster backup.")
        }
        if let backup = choices[.backups].flatMap({ id in volumes.first { $0.id == id } }),!backup.local { warnings.append("Network shares may share a server or storage pool. Backup independence and server permissions have not been certified.") }
        return .init(source: .localRules, choices: choices,
            explanation: "Local rules favor observed local SSDs for active edit state and proxies, then available capacity and reserve. Spacious network storage is preferred for suitable originals and additional copies. All footprint and speed expectations are estimates; no storage was moved.",warnings: warnings,responseSHA256: nil)
    }
    private static func score(_ v: StorageVolume,role: StorageRole,chosen: [StorageRole:String],volumes: [StorageVolume]) -> Int {
        let fast = v.local ? (v.medium == .ssd ? 100 : 65) : 15
        switch role {
        case .edits,.cache: return fast + (v.internalDevice ? 5 : 0)
        case .originals: return (v.local ? 30 : 65) + Int(min(25,v.availableBytes / (100 * StorageWorkload.gib)))
        case .exports: return fast / 2 + (v.local ? 15 : 20)
        case .backups:
            let groups = [StorageRole.edits,.originals].compactMap { role in chosen[role].flatMap { id in volumes.first { $0.id == id }?.capacityGroup } }
            return (!groups.contains(v.capacityGroup) ? 100 : 0) + (v.local ? 15 : 30)
        }
    }
    static func validate(_ advice: StorageAdvice,volumes: [StorageVolume],workload: StorageWorkload) throws {
        try workload.validate()
        guard Set(advice.choices.keys) == Set(StorageRole.allCases) else { throw WorkflowFailure.invalid("Choose an available folder for every storage role.") }
        var needed: [String:Int64] = [:]
        for role in StorageRole.allCases {
            guard let volume = volumes.first(where: { $0.id == advice.choices[role] }), volume.available, volume.writable,volume.totalBytes > 0,volume.availableBytes >= 0 else { throw WorkflowFailure.invalid("A chosen drive is offline or read-only. Reconnect it and review the plan again.") }
            needed[volume.capacityGroup,default: 0] += workload.bytes(for: role)
        }
        for volume in volumes where needed[volume.capacityGroup] != nil {
            guard volume.availableBytes - needed[volume.capacityGroup]! >= workload.reserve(on: volume) else { throw WorkflowFailure.invalid("The proposed locations no longer fit with the reserve. Refresh the available space and review your estimates.") }
        }
    }
}

/// The bookmark grants only a folder the user chose. No whole-disk entitlement
/// or credential is requested; child names are fixed, validated relative leaves.
struct StorageFolderGrant: Codable, Equatable, Sendable {
    var bookmark: Data
    var lastPath: String
    var volumeID: String
    var components: [String]
    var managedRootID: UUID? = nil
    var managedIdentity: RenderDirectoryIdentity? = nil
    var displayPath: String { components.reduce(lastPath) { ($0 as NSString).appendingPathComponent($1) } }
    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." && !value.contains("/") && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    func validateComponents() throws {
        guard components.count <= 8, components.allSatisfy(Self.validComponent) else { throw ProjectFailure.invalidProject }
    }
}

struct StorageProfile: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var confirmed: Date
    var workload: StorageWorkload
    var advice: StorageAdvice
    var folders: [StorageRole:StorageFolderGrant]
    func validate() throws {
        guard schemaVersion == 1, Set(folders.keys) == Set(StorageRole.allCases) else { throw ProjectFailure.invalidProject }
        try workload.validate()
        for (role,folder) in folders {
            try folder.validateComponents()
            guard folder.lastPath.hasPrefix("/"),advice.choices[role] == folder.volumeID else { throw ProjectFailure.invalidProject }
        }
        let paths = folders.values.map { URL(fileURLWithPath: $0.displayPath).standardizedFileURL.path }
        guard !paths.contains("/"), paths.count == Set(paths).count else { throw WorkflowFailure.invalid("Use distinct folders for edit state, originals, cache, exports and backups.") }
        for a in paths { for b in paths where a != b { guard !a.hasPrefix(b+"/") else { throw WorkflowFailure.invalid("Storage role folders must not be nested inside one another.") } } }
    }
}

/// Optional addition to the existing project manifest. Existing projects keep
/// their original paths and all existing engine/run/cut contracts unchanged.
struct ProjectStorageLayout: Codable, Equatable, Sendable {
    var profileID: UUID
    var folders: [StorageRole:String]
}

struct StorageSpaceStatus: Identifiable, Sendable {
    var role: StorageRole
    var path: String
    var availableBytes: Int64?
    var reserveBytes: Int64
    var issue: String?
    var id: String { role.rawValue }
}
