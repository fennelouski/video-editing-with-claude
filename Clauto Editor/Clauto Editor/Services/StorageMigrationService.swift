import Foundation
import Darwin

struct StorageCopyEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case file, directory, link }
    var path: String
    var kind: Kind
    var bytes: Int64
    var signature: [Int64]
    var linkTarget: String?
}

struct StorageMigrationPlan: Codable, Identifiable, Sendable {
    var id: UUID
    var projectID: UUID
    var source: URL
    var destinationParent: URL
    var sourceIdentity: RenderDirectoryIdentity
    var destinationIdentity: RenderDirectoryIdentity
    var destinationVolumeID: String
    var destinationBookmark: Data? = nil
    var entries: [StorageCopyEntry]
    var totalBytes: Int64
    var created: Date
    var fingerprint: String { TranscriptSourceMap.sha((try? CreativeAssetFiles.encoder().encode(self)) ?? Data()) }
}

struct StorageMigrationJournal: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case copying, copyVerified, needsRelink, reopened, playbackChecked, activated, rolledBack, interrupted
        var label: String {
            switch self {
            case .copying: "Copying"
            case .copyVerified: "Copy verified"
            case .needsRelink: "Relink required"
            case .reopened: "Reopened from disk"
            case .playbackChecked: "Content validation complete"
            case .activated: "Copy active"
            case .rolledBack: "Original retained / restored"
            case .interrupted: "Interrupted; partial copy retained"
            }
        }
    }
    var schemaVersion = 1
    var id: UUID
    var plan: StorageMigrationPlan
    var destination: URL
    var state: State
    var copiedSHA256: [String:String]
    var copiedBytes: Int64
    var purpose = "migration"
    var relinkedPathsSHA256: String?
    var relocatedManifestSHA256: String?
    var reopenedFingerprint: String?
    var playbackSource: String?
    var playbackSHA256: String?
    var playbackNonce: UUID?
    var playbackSeconds: Double?
    var unresolvedReferences: [String]
    var failure: String?
    var sourceRetained = true
}

/// Only new exclusive folders are written. Sources, previous versions, and
/// partial evidence are retained, including cancellation or failed validation.
actor StorageMigrationService {
    private let repository = ProjectRepository()
    private let manager = FileManager.default
    private func signature(_ value: stat) -> [Int64] {
        if value.st_mode & S_IFMT == S_IFDIR { return [Int64(value.st_dev),Int64(value.st_ino),0,0,0,0,0] }
        return [Int64(value.st_dev),Int64(value.st_ino),Int64(value.st_size),Int64(value.st_mtimespec.tv_sec),Int64(value.st_mtimespec.tv_nsec),Int64(value.st_ctimespec.tv_sec),Int64(value.st_ctimespec.tv_nsec)]
    }
    private func parent(_ relative: String,at root: SourceRenderDirectory,create: Bool = false) throws -> (SourceRenderDirectory,String) {
        let parts = relative.split(separator: "/",omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,parts.allSatisfy(StorageFolderGrant.validComponent) else { throw ProjectFailure.invalidProject }
        var folder = root
        for leaf in parts.dropLast() { folder = try folder.child(leaf,create: create) }
        return (folder,parts.last!)
    }
    private func inventory(_ root: SourceRenderDirectory) throws -> [StorageCopyEntry] {
        var result: [StorageCopyEntry] = []
        func visit(_ folder: SourceRenderDirectory,_ prefix: String) throws {
            let names = try manager.contentsOfDirectory(atPath: folder.url.path).sorted()
            for name in names {
                try Task.checkCancellation()
                guard StorageFolderGrant.validComponent(name) else { throw ProjectFailure.invalidProject }
                let path = prefix+name
                if path == ".clauto/project-mutation.lock" { continue }
                var info = stat()
                guard fstatat(folder.descriptor,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw ProjectFailure.invalidProject }
                let kind: StorageCopyEntry.Kind
                var target: String?
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    guard !name.hasSuffix(".fcpbundle") else { throw WorkflowFailure.invalid("Final Cut libraries need their own closed-library migration. This tool moves native Clauto projects only.") }
                    kind = .directory
                case S_IFREG:
                    kind = .file
                    if ["sqlite","sqlite3","db","fcpevent","flexolibrary"].contains((name as NSString).pathExtension.lowercased()) {
                        throw WorkflowFailure.invalid("A database file needs a quiescent, application-specific backup. No project copy was started.")
                    }
                case S_IFLNK:
                    kind = .link
                    let link = folder.url.appendingPathComponent(name)
                    let resolved = link.resolvingSymlinksInPath().standardizedFileURL
                    guard manager.fileExists(atPath: resolved.path), (try resolved.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                        throw WorkflowFailure.invalid("Reconnect referenced media before migration. Directory links and missing sources are not copied.")
                    }
                    target = try manager.destinationOfSymbolicLink(atPath: link.path)
                default: throw ProjectFailure.invalidProject
                }
                result.append(.init(path: path,kind: kind,bytes: kind == .file ? info.st_size : 0,signature: signature(info),linkTarget: target))
                guard result.count <= 100_000 else { throw WorkflowFailure.invalid("This copy exceeds the bounded project file inventory. Use a dedicated archival workflow.") }
                if kind == .directory { try visit(folder.child(name),path+"/") }
            }
            try folder.checkPath()
        }
        try visit(root,"")
        return result
    }
    func plan(project: Project,destinationParent: URL) async throws -> StorageMigrationPlan {
        let source = try ProjectMutationLease.checkedRoot(project)
        let destination = try SourceRenderDirectory.open(destinationParent)
        guard source.url != destination.url,!destination.url.path.hasPrefix(source.url.path+"/"),!source.url.path.hasPrefix(destination.url.path+"/") else { throw WorkflowFailure.invalid("Choose a separate destination outside the existing project tree.") }
        let fresh = try await repository.open(source.url)
        guard fresh.id == project.id else { throw ProjectFailure.invalidProject }
        let entries = try inventory(source)
        var bytes: Int64 = 0
        for item in entries { let sum = bytes.addingReportingOverflow(item.bytes); guard !sum.overflow else { throw ProjectFailure.invalidProject }; bytes = sum.partialValue }
        return .init(id: UUID(),projectID: project.id,source: source.url,destinationParent: destination.url,sourceIdentity: source.identity,destinationIdentity: destination.identity,destinationVolumeID: try StorageVolumeProbe.observe(destination.url).id,entries: entries,totalBytes: bytes,created: Date())
    }
    private func save(_ journal: StorageMigrationJournal) throws {
        let root = try SourceRenderDirectory.open(journal.destination.deletingLastPathComponent())
        try root.replacePointer(CreativeAssetFiles.encoder().encode(journal),name: "storage-migration.json")
    }
    func load(_ destination: URL) throws -> StorageMigrationJournal {
        let root = try SourceRenderDirectory.open(destination)
        let parent = try SourceRenderDirectory.open(root.url.deletingLastPathComponent())
        let journal = try CreativeAssetFiles.decode(parent.read("storage-migration.json",limit: 64*1024*1024),as: StorageMigrationJournal.self)
        guard journal.schemaVersion == 1,journal.id == journal.plan.id,journal.sourceRetained,
              journal.destination.resolvingSymlinksInPath().standardizedFileURL == root.url,
              root.url.lastPathComponent == "Project",parent.url.lastPathComponent == "Clauto-copy-"+journal.id.uuidString,
              parent.url.deletingLastPathComponent() == journal.plan.destinationParent,
              try SourceRenderDirectory.open(journal.plan.destinationParent).identity == journal.plan.destinationIdentity,
              journal.plan.entries.count <= 100_000,journal.plan.entries.allSatisfy({ $0.bytes >= 0 && !$0.path.isEmpty && $0.path.split(separator: "/",omittingEmptySubsequences: false).allSatisfy { StorageFolderGrant.validComponent(String($0)) } }) else { throw WorkflowFailure.invalid("The migration journal or destination identity changed. No activation or source removal is allowed.") }
        return journal
    }
    func copy(_ plan: StorageMigrationPlan,confirmedFingerprint: String,reserveBytes: Int64,purpose: String = "migration",
              progress: @escaping @Sendable (Int64,Int64) async -> Void = { _,_ in }) async throws -> StorageMigrationJournal {
        guard ["migration","backup"].contains(purpose),confirmedFingerprint == plan.fingerprint, (0...600).contains(Date().timeIntervalSince(plan.created)) else { throw WorkflowFailure.invalid("The copy plan changed or expired. Review its exact paths and footprint again.") }
        let project = try await repository.open(plan.source)
        guard project.id == plan.projectID else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        guard lease.root.identity == plan.sourceIdentity, try inventory(lease.root) == plan.entries else { throw WorkflowFailure.invalid("Source files changed after review. Refresh the plan; no copy was started.") }
        let parent = try SourceRenderDirectory.open(plan.destinationParent)
        guard parent.identity == plan.destinationIdentity else { throw WorkflowFailure.invalid("The destination folder changed after review. No copy was started.") }
        let volume = try StorageVolumeProbe.observe(parent.url)
        guard volume.writable, reserveBytes >= 0, volume.availableBytes-plan.totalBytes >= reserveBytes else { throw WorkflowFailure.invalid("The destination no longer has the reviewed space plus reserve.") }
        let transaction = try parent.child("Clauto-copy-"+plan.id.uuidString,create: true,exclusive: true)
        let output = try transaction.child("Project",create: true,exclusive: true)
        var journal = StorageMigrationJournal(id: plan.id,plan: plan,destination: output.url,state: .copying,copiedSHA256: [:],copiedBytes: 0,unresolvedReferences: [])
        journal.purpose = purpose
        try save(journal)
        do {
            for entry in plan.entries {
                try Task.checkCancellation()
                let (input,name) = try self.parent(entry.path,at: lease.root)
                let (destination,leaf) = try self.parent(entry.path,at: output,create: true)
                var info = stat()
                guard fstatat(input.descriptor,name,&info,AT_SYMLINK_NOFOLLOW) == 0,signature(info) == entry.signature else { throw WorkflowFailure.invalid("A source file changed. The incomplete copy and original are retained.") }
                switch entry.kind {
                case .directory: _ = try destination.child(leaf,create: true)
                case .file:
                    let sha = try input.voiceHash(name,limit: max(1,entry.bytes),copyTo: destination,destinationName: leaf)
                    guard try destination.voiceHash(leaf,limit: max(1,entry.bytes)) == sha else { throw WorkflowFailure.invalid("Destination readback did not match. Both copies are retained.") }
                    journal.copiedSHA256[entry.path] = sha; journal.copiedBytes += entry.bytes
                case .link:
                    let resolved = input.url.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
                    let linkTarget = resolved.path.hasPrefix(plan.source.path+"/") ? output.url.path+String(resolved.path.dropFirst(plan.source.path.count)) : resolved.path
                    guard symlinkat(linkTarget,destination.descriptor,leaf) == 0 else { throw ProjectFailure.invalidProject }
                    journal.copiedSHA256[entry.path] = TranscriptSourceMap.sha(Data(linkTarget.utf8))
                }
                try lease.root.checkPath(); try output.checkPath(); try save(journal)
                await progress(journal.copiedBytes,plan.totalBytes)
            }
            guard try inventory(lease.root) == plan.entries else { throw WorkflowFailure.invalid("The project changed during copying. No relink or activation occurred.") }
            journal.state = .copyVerified; try save(journal)
            return journal
        } catch {
            journal.state = .interrupted; journal.failure = error is CancellationError ? "Copy cancelled. Original and partial evidence retained." : error.localizedDescription
            let retained = journal
            // Persist failure even when the user's copy task was cancelled.
            // This new awaited task writes only our journal, never the source.
            await Task.detached { [self] in try? await save(retained) }.value
            throw error
        }
    }
    /// Rebases only the known project paths contract. Immutable cuts and review
    /// receipts are never rewritten. Legacy dependencies fail closed for review.
    func relink(_ destination: URL) async throws -> StorageMigrationJournal {
        var journal = try load(destination)
        guard journal.state == .copyVerified else { throw ProjectFailure.invalidProject }
        try verifyCopiedFiles(journal)
        let root = try SourceRenderDirectory.open(destination)
        var paths = try JSONDecoder().decode([String:String].self,from: root.read("paths.json",limit: 1024*1024))
        for key in ["footage","assets","build","cuts","script"] {
            guard paths[key].map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == journal.plan.source.appendingPathComponent(key).path }) == true else { throw WorkflowFailure.invalid("This project has a custom storage contract. Its copy is retained for a supported relink; no saved cut was changed.") }
            paths[key] = destination.appendingPathComponent(key).path
        }
        let bytes = try JSONEncoder().encode(paths)
        try root.replacePointer(bytes,name: "paths.json")
        journal.relinkedPathsSHA256 = TranscriptSourceMap.sha(bytes)
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(ProjectManifest.self,from: root.read("clauto-project.json",limit: 8*1024*1024))
        if manifest.storageLayout != nil {
            manifest.storageLayout?.folders[.edits] = destination.path
            let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
            let bytes = try encoder.encode(manifest)
            try root.replacePointer(bytes,name: "clauto-project.json")
            journal.relocatedManifestSHA256 = TranscriptSourceMap.sha(bytes)
        }
        let oldPath = journal.plan.source.path, oldURI = journal.plan.source.absoluteString
        for entry in journal.plan.entries where entry.kind == .file && entry.path != "paths.json" && (entry.path.hasSuffix(".json") || entry.path.hasSuffix(".fcpxml")) && entry.bytes <= 16*1024*1024 {
            let (folder,leaf) = try parent(entry.path,at: root)
            let text = String(decoding: try folder.read(leaf,limit: 16*1024*1024),as: UTF8.self)
            // JSON escapes (including unicode slash escapes) must not hide sealed
            // references. Decode strings recursively; XML URI percent escapes
            // are conservatively checked without rewriting evidence.
            func references(_ value: Any) -> Bool {
                if let string = value as? String { return string.contains(oldPath) || string.contains(oldURI) || (string.removingPercentEncoding?.contains(oldPath) ?? false) }
                if let values = value as? [Any] { return values.contains(where: references) }
                if let values = value as? [String:Any] { return values.contains { references($0.key) || references($0.value) } }
                return false
            }
            let decoded = entry.path.hasSuffix(".json") ? try? JSONSerialization.jsonObject(with: Data(text.utf8),options: [.fragmentsAllowed]) : nil
            if text.contains(oldPath) || text.contains(oldURI) || (text.removingPercentEncoding?.contains(oldPath) ?? false) || decoded.map(references) == true { journal.unresolvedReferences.append(entry.path) }
        }
        journal.state = journal.unresolvedReferences.isEmpty ? .copyVerified : .needsRelink
        if !journal.unresolvedReferences.isEmpty { journal.failure = "Legacy run/cut metadata still names the original project folder. Keep the source. This tool will not rewrite sealed evidence." }
        try save(journal); return journal
    }
    private func verifyCopiedFiles(_ journal: StorageMigrationJournal) throws {
        let root = try SourceRenderDirectory.open(journal.destination)
        let current = try inventory(root)
        guard Set(current.map { $0.path+":"+$0.kind.rawValue }) == Set(journal.plan.entries.map { $0.path+":"+$0.kind.rawValue }) else { throw WorkflowFailure.invalid("The copied project's file inventory changed. Both projects are retained.") }
        for entry in journal.plan.entries where entry.kind == .file {
            let (folder,leaf) = try parent(entry.path,at: root)
            let expected = entry.path == "paths.json" ? (journal.relinkedPathsSHA256 ?? journal.copiedSHA256[entry.path]) : entry.path == "clauto-project.json" ? (journal.relocatedManifestSHA256 ?? journal.copiedSHA256[entry.path]) : journal.copiedSHA256[entry.path]
            guard try folder.voiceHash(leaf,limit: max(1,entry.path == "paths.json" ? 1024*1024 : entry.path == "clauto-project.json" ? 8*1024*1024 : entry.bytes)) == expected else { throw WorkflowFailure.invalid("The copied project changed after verification. Reopen/review it; activation is paused.") }
        }
        for entry in journal.plan.entries where entry.kind == .link {
            let link = root.url.appendingPathComponent(entry.path)
            let value = try manager.destinationOfSymbolicLink(atPath: link.path)
            guard TranscriptSourceMap.sha(Data(value.utf8)) == journal.copiedSHA256[entry.path] else { throw WorkflowFailure.invalid("A copied media link changed. Activation is paused.") }
        }
    }
    func reopen(_ destination: URL) async throws -> (StorageMigrationJournal,Project,URL?) {
        var journal = try load(destination)
        guard journal.state == .copyVerified, journal.relinkedPathsSHA256 != nil,journal.unresolvedReferences.isEmpty else { throw WorkflowFailure.invalid("Finish the supported relink before reopening the copied project.") }
        try verifyCopiedFiles(journal)
        // Fresh repository and directory handles after copy/relink have closed.
        let project = try await ProjectRepository().open(destination)
        guard project.id == journal.plan.projectID else { throw ProjectFailure.invalidProject }
        let version = try await WorkflowRepository().current(project: project)
        let movie = version.flatMap { v in v.artifacts.first(where: { ["mp4","mov"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }).map { project.folder.appendingPathComponent("cuts/"+v.folderName+"/"+$0) } }
        let fallback = project.manifest.files.first(where: { $0.group == .footage || $0.group == .audio }).map { project.folder.appendingPathComponent($0.relativePath).resolvingSymlinksInPath() }
        let preview = movie ?? fallback
        journal.reopenedFingerprint = journal.plan.fingerprint
        journal.playbackNonce = UUID(); journal.playbackSource = preview?.path
        if let preview {
            let folder = try SourceRenderDirectory.open(preview.deletingLastPathComponent())
            journal.playbackSHA256 = try folder.voiceHash(preview.lastPathComponent,limit: Int64.max / 4)
        }
        journal.state = .reopened; try save(journal)
        return (journal,project,preview)
    }
    func confirmPlayback(_ destination: URL,nonce: UUID,observedSeconds: Double,humanChecked: Bool) throws -> StorageMigrationJournal {
        var journal = try load(destination)
        guard journal.state == .reopened,journal.playbackNonce == nonce,journal.playbackSource != nil,
              humanChecked,observedSeconds.isFinite,observedSeconds >= 1 else { throw WorkflowFailure.invalid("Play and inspect the copied project's media before confirming content and sync. No playback proof was inferred.") }
        try verifyCopiedFiles(journal)
        let movie = URL(fileURLWithPath: journal.playbackSource!)
        guard try SourceRenderDirectory.open(movie.deletingLastPathComponent()).voiceHash(movie.lastPathComponent,limit: Int64.max / 4) == journal.playbackSHA256 else { throw ProjectFailure.invalidProject }
        journal.playbackSeconds = observedSeconds; journal.state = .playbackChecked; try save(journal); return journal
    }
    func confirmEmptyProject(_ destination: URL,nonce: UUID,humanChecked: Bool) async throws -> StorageMigrationJournal {
        var journal = try load(destination)
        guard journal.state == .reopened,journal.playbackNonce == nonce,journal.playbackSource == nil,humanChecked else { throw ProjectFailure.invalidProject }
        let project = try await repository.open(destination)
        guard project.manifest.files.isEmpty,try await WorkflowRepository().current(project: project) == nil else { throw WorkflowFailure.invalid("This project has media or a saved cut. Complete playback validation instead.") }
        try verifyCopiedFiles(journal)
        journal.state = .playbackChecked;journal.failure = "Playback not applicable: reopened project has no sources or saved cut, explicitly checked by user."
        try save(journal);return journal
    }
    func markActivated(_ destination: URL) throws -> StorageMigrationJournal {
        var journal = try activationReceipt(destination)
        journal.state = .activated; try save(journal); return journal
    }
    func activationReceipt(_ destination: URL) throws -> StorageMigrationJournal {
        var journal = try load(destination)
        guard journal.purpose == "migration",journal.state == .playbackChecked,try inventory(SourceRenderDirectory.open(journal.plan.source)) == journal.plan.entries else { throw WorkflowFailure.invalid("The source or validation state changed. Review both projects before activation.") }
        try verifyCopiedFiles(journal)
        journal.state = .activated;return journal
    }
    func rollback(_ destination: URL) async throws -> StorageMigrationJournal {
        var journal = try load(destination)
        let original = try await repository.open(journal.plan.source)
        guard original.id == journal.plan.projectID,try inventory(ProjectMutationLease.checkedRoot(original)) == journal.plan.entries else { throw WorkflowFailure.invalid("The original changed. Both projects are retained for manual review; rollback will not discard new work.") }
        if journal.state == .activated { try verifyCopiedFiles(journal) }
        journal.state = .rolledBack; journal.failure = nil; try save(journal); return journal
    }
    func verifiedFileCopy(_ source: URL,to parentURL: URL,reserveBytes: Int64,label: String) throws -> URL {
        let input = try SourceRenderDirectory.open(source.deletingLastPathComponent())
        let parent = try SourceRenderDirectory.open(parentURL)
        var info = stat(); guard fstatat(input.descriptor,source.lastPathComponent,&info,AT_SYMLINK_NOFOLLOW) == 0,info.st_mode & S_IFMT == S_IFREG else { throw ProjectFailure.invalidProject }
        let volume = try StorageVolumeProbe.observe(parent.url)
        guard volume.writable,volume.availableBytes-info.st_size >= reserveBytes else { throw WorkflowFailure.invalid("The destination cannot preserve your reserve for this copy.") }
        let output = try parent.child(UUID().uuidString,create: true,exclusive: true)
        let sha = try input.voiceHash(source.lastPathComponent,limit: max(1,info.st_size),copyTo: output)
        guard try output.voiceHash(source.lastPathComponent,limit: max(1,info.st_size)) == sha else { throw ProjectFailure.invalidProject }
        let receipt: [String:String] = ["source":source.path,"destination":output.url.appendingPathComponent(source.lastPathComponent).path,"sha256":sha,"purpose":label,"sourceRetained":"true"]
        try output.writeNew(JSONEncoder().encode(receipt),name: "verified-copy.json")
        return output.url.appendingPathComponent(source.lastPathComponent)
    }
}
