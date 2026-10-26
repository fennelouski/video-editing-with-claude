import Foundation
import Darwin
import DiskArbitration
import IOKit

enum StorageVolumeProbe {
    static func observe(_ url: URL) throws -> StorageVolume {
        try ProjectRepository.validateDrive(url)
        let root = try SourceRenderDirectory.open(url)
        var fs = statfs()
        guard fstatfs(root.descriptor,&fs) == 0 else { throw ProjectFailure.unavailableDrive }
        let keys: Set<URLResourceKey> = [.volumeURLKey,.volumeUUIDStringKey,.volumeNameKey,.volumeIsInternalKey,.volumeAvailableCapacityForImportantUsageKey]
        let values = try root.url.resourceValues(forKeys: keys)
        let volumeURL = values.volume ?? root.url
        let local = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
        let filesystem = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self,capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
        let device = deviceInfo(volumeURL)
        let bytes: (UInt64) -> Int64 = { Int64(min(Double(Int64.max / 2),Double($0)*Double(fs.f_bsize))) }
        let identifier = values.volumeUUIDString ?? "\(filesystem):\(root.identity.device):\(volumeURL.path)"
        return .init(id: identifier,name: values.volumeName ?? volumeURL.lastPathComponent,path: volumeURL.path,
            capacityGroup: device.group ?? identifier,filesystem: filesystem,totalBytes: bytes(fs.f_blocks),availableBytes: bytes(fs.f_bavail),
            importantUsageBytes: values.volumeAvailableCapacityForImportantUsage,local: local,internalDevice: values.volumeIsInternal ?? false,
            medium: device.medium,writable: (fs.f_flags & UInt32(MNT_RDONLY)) == 0 && FileManager.default.isWritableFile(atPath: root.url.path),
            available: true,observed: Date(),performance: .estimate(local: local,medium: device.medium))
    }
    private static func deviceInfo(_ url: URL) -> (group: String?, medium: StorageVolume.Medium) {
        guard let session = DASessionCreate(kCFAllocatorDefault), let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault,session,url as CFURL) else { return (nil,.unknown) }
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        let group = DADiskGetBSDName(whole).map { "disk:"+String(cString: $0) }
        guard let bsd = DADiskGetBSDName(whole) else { return (group,.unknown) }
        let service = IOServiceGetMatchingService(kIOMainPortDefault,IOBSDNameMatching(kIOMainPortDefault,0,bsd))
        guard service != 0 else { return (group,.unknown) }; defer { IOObjectRelease(service) }
        let flags = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let properties = IORegistryEntrySearchCFProperty(service,kIOServicePlane,"Device Characteristics" as CFString,kCFAllocatorDefault,flags) as? [String:Any]
        let medium: StorageVolume.Medium = switch properties?["Medium Type"] as? String {
        case "Solid State": .ssd
        case "Rotational": .rotational
        default: .unknown
        }
        return (group,medium)
    }
}

final class StorageFolderAccess: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(_ grant: StorageFolderGrant) throws {
        try grant.validateComponents()
        var stale = false
        url = try URL(resolvingBookmarkData: grant.bookmark,options: [.withSecurityScope,.withoutUI,.withoutMounting],bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL else { throw WorkflowFailure.invalid("Folder access needs reconnection. Choose that folder again; the saved path was retained.") }
        scoped = url.startAccessingSecurityScopedResource()
        do {
            guard try StorageVolumeProbe.observe(url).id == grant.volumeID else { throw WorkflowFailure.invalid("The selected folder is on a different volume. Review its new location before using it.") }
        } catch { if scoped { url.stopAccessingSecurityScopedResource() }; throw error }
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct StorageManagedRoot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var owner = "com.nathanfennel.Clauto-Editor"
    var id: UUID
    var role: StorageRole
    static let marker = ".clauto-storage-root.json"
}

actor StorageWorkspaceService {
    func volumes() throws -> [StorageVolume] {
        var urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],options: [.skipHiddenVolumes]) ?? []
        urls.insert(FileManager.default.homeDirectoryForCurrentUser,at: 0)
        var result: [StorageVolume] = [],seen = Set<String>()
        for url in urls {
            try Task.checkCancellation()
            if let volume = try? StorageVolumeProbe.observe(url), seen.insert(volume.id).inserted { result.append(volume) }
        }
        return result.sorted { $0.local != $1.local ? $0.local : $0.name < $1.name }
    }
    func grant(folder: URL,role: StorageRole) throws -> StorageFolderGrant {
        let volume = try StorageVolumeProbe.observe(folder)
        guard volume.writable else { throw WorkflowFailure.invalid("Choose a writable folder.") }
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope],includingResourceValuesForKeys: [.volumeUUIDStringKey],relativeTo: nil)
        return .init(bookmark: bookmark,lastPath: folder.resolvingSymlinksInPath().standardizedFileURL.path,volumeID: volume.id,components: ["Clauto Video",role.folderName])
    }
    func resolved(_ grant: StorageFolderGrant,create: Bool = false,role: StorageRole? = nil) throws -> URL {
        let access = try StorageFolderAccess(grant); defer { withExtendedLifetime(access) {} }
        var directory = try SourceRenderDirectory.open(access.url)
        for component in grant.components { try directory.checkPath(); directory = try directory.child(component,create: create) }
        try directory.checkPath()
        if let role {
            let marker = try managedRoot(directory,role: role,create: create)
            guard grant.managedRootID == nil || marker.id == grant.managedRootID,
                  grant.managedIdentity == nil || directory.identity == grant.managedIdentity else { throw WorkflowFailure.invalid("This owned storage folder changed or reconnected. Reconnect and review the folder before new writes.") }
        }
        return directory.url
    }
    func managedRoot(_ directory: SourceRenderDirectory,role: StorageRole,create: Bool = false) throws -> StorageManagedRoot {
        if try CreativeAssetFiles.exists(StorageManagedRoot.marker,in: directory) {
            let record = try CreativeAssetFiles.decode(directory.read(StorageManagedRoot.marker,limit: 4096),as: StorageManagedRoot.self)
            guard record.schemaVersion == 1, record.owner == "com.nathanfennel.Clauto-Editor",record.role == role else { throw WorkflowFailure.invalid("This folder is already managed for a different purpose. Choose another folder.") }
            return record
        }
        guard create else { throw WorkflowFailure.invalid("This folder is not an app-managed cache or storage root.") }
        let record = StorageManagedRoot(id: UUID(),role: role)
        try directory.writeNew(JSONEncoder().encode(record),name: StorageManagedRoot.marker)
        return record
    }
    func validatePlan(_ profile: StorageProfile) throws {
        try profile.validate()
        var observed: [StorageVolume] = []
        for grant in profile.folders.values {
            let access = try StorageFolderAccess(grant); defer { withExtendedLifetime(access) {} }
            let volume = try StorageVolumeProbe.observe(access.url)
            if !observed.contains(where: { $0.id == volume.id }) { observed.append(volume) }
        }
        try StorageRecommendation.validate(profile.advice,volumes: observed,workload: profile.workload)
    }
    func prepare(_ profile: StorageProfile) throws -> [StorageRole:URL] {
        try validatePlan(profile)
        var paths: [StorageRole:URL] = [:]
        for role in StorageRole.allCases {
            try Task.checkCancellation()
            paths[role] = try resolved(profile.folders[role]!,create: true,role: role)
        }
        return paths
    }
    func boundProfile(_ profile: StorageProfile) throws -> StorageProfile {
        var next = profile
        for role in StorageRole.allCases {
            let folder = try SourceRenderDirectory.open(resolved(profile.folders[role]!,role: role))
            next.folders[role]?.managedRootID = try managedRoot(folder,role: role).id
            next.folders[role]?.managedIdentity = folder.identity
        }
        return next
    }
    func monitor(_ profile: StorageProfile) -> [StorageSpaceStatus] {
        StorageRole.allCases.map { role in
            guard let grant = profile.folders[role] else { return .init(role: role,path: "Not configured",availableBytes: nil,reserveBytes: 0,issue: "Choose a folder.") }
            do {
                let access = try StorageFolderAccess(grant); defer { withExtendedLifetime(access) {} }
                let volume = try StorageVolumeProbe.observe(access.url), reserve = profile.workload.reserve(on: volume)
                if grant.managedRootID != nil { _ = try resolved(grant,role: role) }
                return .init(role: role,path: grant.displayPath,availableBytes: volume.availableBytes,reserveBytes: reserve,
                    issue: !volume.writable ? "Read-only volume. New writes are paused." : volume.availableBytes < reserve ? "Available space is below your reserve. New copies and cache jobs are paused." : nil)
            } catch { return .init(role: role,path: grant.displayPath,availableBytes: nil,reserveBytes: 0,issue: "Offline or folder access needs reconnection. No fallback folder was substituted.") }
        }
    }
    func requireSpace(_ profile: StorageProfile,role: StorageRole,bytes: Int64) throws -> URL {
        guard bytes >= 0, let grant = profile.folders[role] else { throw ProjectFailure.invalidProject }
        let access = try StorageFolderAccess(grant); defer { withExtendedLifetime(access) {} }
        let volume = try StorageVolumeProbe.observe(access.url)
        guard volume.writable, volume.availableBytes - bytes >= profile.workload.reserve(on: volume) else { throw WorkflowFailure.invalid("This write would use the configured reserve, or the drive is unavailable. Free recoverable space, reduce the request, or choose another folder.") }
        return try resolved(grant,role: role)
    }
}
