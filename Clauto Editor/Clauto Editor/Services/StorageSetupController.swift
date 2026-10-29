import Foundation
import Observation

@MainActor @Observable final class StorageSetupController {
    private(set) var volumes: [StorageVolume] = []
    var workload = StorageWorkload() { didSet { reviewedProfile = nil;formID = UUID() } }
    private(set) var advice: StorageAdvice?
    private(set) var folders: [StorageRole:StorageFolderGrant] = [:]
    private(set) var profile: StorageProfile?
    private(set) var reviewedProfile: StorageProfile?
    private(set) var choosingFolderRoles: Set<StorageRole> = []
    private(set) var space: [StorageSpaceStatus] = []
    private(set) var busy = false
    private(set) var message: String?
    private(set) var error: String?
    private(set) var cacheItems: [StorageCacheItem] = []
    private(set) var trashReceipts: [StorageCacheTrashReceipt] = []
    var cachePreview: URL?
    private(set) var copyPlan: StorageMigrationPlan?
    private(set) var journal: StorageMigrationJournal? {
        didSet {
            guard let journal else { return }
            journalHistory.removeAll { $0.id == journal.id };journalHistory.append(journal)
            retainMigrationScopes()
            if let bytes = try? JSONEncoder().encode(journalHistory) { defaults.set(bytes,forKey: "ClautoStorageMigrationJournals") }
        }
    }
    private(set) var journalHistory: [StorageMigrationJournal] = []
    private(set) var progressBytes: Int64 = 0
    private(set) var copyPurpose = "migration"
    private(set) var playbackURL: URL?
    var observedPlaybackSeconds = 0.0
    var humanCheckedPlayback = false
    @ObservationIgnored private let service: StorageWorkspaceService
    @ObservationIgnored private let migration: StorageMigrationService
    @ObservationIgnored private let cache: StorageCacheService
    @ObservationIgnored private let advisor: any StorageAdvising
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var histories: [StorageProfile] = []
    @ObservationIgnored private var access: [StorageFolderAccess] = []
    @ObservationIgnored private var destinationAccess: StorageFolderAccess?
    @ObservationIgnored private var migrationAccess: [String:StorageFolderAccess] = [:]
    @ObservationIgnored private var monitorTask: Task<Void,Never>?
    @ObservationIgnored private var operation: Task<Void,Never>?
    @ObservationIgnored private var intakeTask: Task<([URL],[String:String]),Error>?
    @ObservationIgnored private var cacheProfileID: UUID?
    @ObservationIgnored private var formID = UUID()
    @ObservationIgnored private var folderChoices: [StorageRole:UUID] = [:]
    @ObservationIgnored private let folderGrant: @Sendable (URL,StorageRole) async throws -> StorageFolderGrant
    @ObservationIgnored private let canLock: @MainActor (Project) -> Bool
    @ObservationIgnored private let release: @MainActor () -> Void
    @ObservationIgnored private let protectedPaths: @MainActor () -> [URL]
    @ObservationIgnored private let activate: @MainActor (Project,StorageMigrationJournal) async throws -> Void
    init(defaults: UserDefaults,service: StorageWorkspaceService = .init(),migration: StorageMigrationService = .init(),cache: StorageCacheService = .init(),advisor: any StorageAdvising = ConnectedStorageAdvisor(),folderGrant: (@Sendable (URL,StorageRole) async throws -> StorageFolderGrant)? = nil,
         canLock: @escaping @MainActor (Project)->Bool = { _ in false },release: @escaping @MainActor ()->Void = {},protectedPaths: @escaping @MainActor ()->[URL] = { [] },activate: @escaping @MainActor (Project,StorageMigrationJournal) async throws -> Void = { _,_ in throw ProjectFailure.invalidProject }) {
        self.defaults = defaults;self.service = service;self.migration = migration;self.cache = cache;self.advisor = advisor;self.canLock = canLock;self.release = release;self.protectedPaths = protectedPaths;self.activate = activate
        self.folderGrant = folderGrant ?? { try await service.grant(folder: $0,role: $1) }
        if let bytes = defaults.data(forKey: "ClautoStorageProfiles"),let records = try? JSONDecoder().decode([StorageProfile].self,from: bytes) {
            histories = records.filter { (try? $0.validate()) != nil }
            profile = histories.first { $0.id.uuidString == defaults.string(forKey: "ClautoActiveStorageProfile") }
            if let profile { workload = profile.workload;advice = profile.advice;folders = profile.folders }
            retainScopes()
        }
        if let bytes = defaults.data(forKey: "ClautoStorageTrashReceipts") { trashReceipts = (try? JSONDecoder().decode([StorageCacheTrashReceipt].self,from: bytes)) ?? [] }
        if let bytes = defaults.data(forKey: "ClautoStorageMigrationJournals") { journalHistory = (try? JSONDecoder().decode([StorageMigrationJournal].self,from: bytes)) ?? [] }
        retainMigrationScopes()
    }
    private func retainMigrationScopes() {
        for journal in journalHistory {
            guard let bookmark = journal.plan.destinationBookmark,migrationAccess[journal.plan.destinationParent.path] == nil else { continue }
            migrationAccess[journal.plan.destinationParent.path] = try? StorageFolderAccess(.init(bookmark: bookmark,lastPath: journal.plan.destinationParent.path,volumeID: journal.plan.destinationVolumeID,components: []))
        }
    }
    private func retainScopes() {
        var retained: [StorageFolderAccess] = [],seen = Set<String>()
        for grant in histories.reversed().flatMap({ $0.folders.values }) {
            let key = grant.volumeID+":"+grant.lastPath
            if !seen.contains(key),let scope = try? StorageFolderAccess(grant) { retained.append(scope);seen.insert(key) }
        }
        access = retained
    }
    func selectVolume(_ id: String,role: StorageRole) {
        folderChoices.removeValue(forKey: role);choosingFolderRoles.remove(role)
        advice?.choices[role] = id;folders.removeValue(forKey: role);reviewedProfile = nil;formID = UUID()
    }
    func reuseBase(from role: StorageRole) {
        guard let base = folders[role] else { return }
        for other in StorageRole.allCases where advice?.choices[other] == base.volumeID {
            folderChoices.removeValue(forKey: other);choosingFolderRoles.remove(other)
            var grant = base;grant.components = ["Clauto Video",other.folderName];grant.managedRootID = nil;grant.managedIdentity = nil;folders[other] = grant
        }
        reviewedProfile = nil;formID = UUID()
    }
    func continueJournal(_ value: StorageMigrationJournal) {
        if let bookmark = value.plan.destinationBookmark {
            destinationAccess = try? StorageFolderAccess(.init(bookmark: bookmark,lastPath: value.plan.destinationParent.path,volumeID: value.plan.destinationVolumeID,components: []))
        }
        journal = value;copyPlan = value.plan;copyPurpose = value.purpose;playbackURL = nil;humanCheckedPlayback = false;observedPlaybackSeconds = 0
    }
    func refresh() async {
        do {
            volumes = try await service.volumes()
            if advice == nil { advice = try StorageRecommendation.local(volumes: volumes,workload: workload) }
            if let profile { space = await service.monitor(profile) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func recommend(useConnectedAI: Bool = true) async {
        guard !busy else { return }
        busy = true;defer { busy = false };reviewedProfile = nil;formID = UUID()
        folderChoices = [:];choosingFolderRoles = []
        await perform { [self] in
        do {
            volumes = try await service.volumes()
            advice = try StorageRecommendation.local(volumes: volumes,workload: workload)
            folders = [:]
            guard useConnectedAI else { message = "Local recommendations. No AI request was sent.";return }
            do {
                advice = try await advisor.recommend(volumes: volumes,workload: workload)
                message = "Connected Claude suggested these drive roles from aggregate capacity/device facts. No project files or paths were sent. Review every folder before confirming."
            } catch is CancellationError { throw CancellationError() }
            catch { message = "Connected AI is unavailable or its answer did not pass space checks. The displayed plan uses local rules; no sign-in or paid service was added." }
            error = nil
        } catch { self.error = error.localizedDescription }
        }
    }
    func choose(role: StorageRole,folder: URL) async {
        guard !busy else { return }
        let choice = UUID();folderChoices[role] = choice;choosingFolderRoles.insert(role)
        // Invalidate consent before awaiting bookmark/volume resolution, not
        // only when a potentially delayed answer comes back.
        reviewedProfile = nil;formID = UUID()
        defer {
            if folderChoices[role] == choice { folderChoices.removeValue(forKey: role);choosingFolderRoles.remove(role) }
        }
        do {
            let grant = try await folderGrant(folder,role)
            guard folderChoices[role] == choice else { return }
            folders[role] = grant;advice?.choices[role] = grant.volumeID;reviewedProfile = nil;formID = UUID();error = nil
            if !volumes.contains(where: { $0.id == grant.volumeID }) { volumes.append(try StorageVolumeProbe.observe(folder)) }
        } catch { if folderChoices[role] == choice { self.error = error.localizedDescription } }
    }
    func review() async {
        guard !busy,let advice else { return }
        guard choosingFolderRoles.isEmpty else { error = "Wait for the selected folders to finish checking before reviewing locations.";return }
        let revision = formID
        do {
            let draft = StorageProfile(id: revision,confirmed: Date(),workload: workload,advice: advice,folders: folders)
            try draft.validate()
            try await service.validatePlan(draft)
            guard formID == revision,choosingFolderRoles.isEmpty else { return }
            // Monitoring resolves existing bookmarks; no folder is created here.
            let status = await service.monitor(draft)
            guard formID == revision,choosingFolderRoles.isEmpty else { return }
            guard status.allSatisfy({ $0.issue == nil }) else { throw WorkflowFailure.invalid("Reconnect offline folders or resolve the reserve warnings before confirming.") }
            reviewedProfile = draft;error = nil
        } catch { if formID == revision { self.error = error.localizedDescription } }
    }
    func confirmProfile() async -> URL? {
        guard !busy,choosingFolderRoles.isEmpty,let reviewedProfile,reviewedProfile.id == formID else { error = "Review the exact folder proposal first.";return nil }
        busy = true;defer { busy = false }
        do {
            let paths = try await service.prepare(reviewedProfile)
            let confirmed = try await service.boundProfile(reviewedProfile)
            guard self.reviewedProfile?.id == reviewedProfile.id,formID == reviewedProfile.id else { throw WorkflowFailure.invalid("The proposal changed during preparation. Review it again before saving.") }
            histories.removeAll { $0.id == confirmed.id };histories.append(confirmed)
            defaults.set(try JSONEncoder().encode(histories),forKey: "ClautoStorageProfiles")
            defaults.set(confirmed.id.uuidString,forKey: "ClautoActiveStorageProfile")
            profile = confirmed;folders = confirmed.folders;self.reviewedProfile = nil;retainScopes()
            space = await service.monitor(confirmed)
            message = "Locations confirmed for new work. Existing projects, current cuts and original media were not moved."
            error = nil;return paths[.edits]
        } catch { self.error = "Storage setup could not finish. The previous profile remains selected. Some new owned folders may exist for review. "+error.localizedDescription;return nil }
    }
    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let profile { space = await service.monitor(profile) }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func validateProjectWrites(_ project: Project) async throws {
        guard let layout = project.manifest.storageLayout else { return }
        guard let selected = histories.first(where: { $0.id == layout.profileID }) else { throw WorkflowFailure.invalid("Reconnect this project's saved storage profile before starting a new run.") }
        _ = try ProjectMutationLease.checkedRoot(project)
        let base = try await service.requireSpace(selected,role: .cache,bytes: 0)
        guard layout.folders[.cache] == base.appendingPathComponent(project.id.uuidString).path else { throw ProjectFailure.invalidProject }
        _ = try SourceRenderDirectory.open(base).child(project.id.uuidString)
    }
    func rootsForNewProject() async throws -> (StorageProfile,[StorageRole:URL])? {
        guard let profile else { return nil }
        try await service.validatePlan(profile)
        var roots: [StorageRole:URL] = [:]
        for role in StorageRole.allCases { roots[role] = try await service.requireSpace(profile,role: role,bytes: profile.workload.bytes(for: role)) }
        return (profile,roots)
    }
    func root(for role: StorageRole,project: Project? = nil,bytes: Int64 = 0) async throws -> URL {
        let selected: StorageProfile?
        if let id = project?.manifest.storageLayout?.profileID { selected = histories.first { $0.id == id } }
        else { selected = profile }
        guard let selected else { throw WorkflowFailure.invalid("Confirm storage locations in Workspace first. A project from another Mac may need folder reconnection.") }
        let base = try await service.requireSpace(selected,role: role,bytes: bytes)
        guard let project else { return base }
        if role == .edits {
            guard project.manifest.storageLayout?.folders[.edits] == project.folder.path else { throw ProjectFailure.invalidProject }
            return try ProjectMutationLease.checkedRoot(project).url
        }
        if let layout = project.manifest.storageLayout {
            guard layout.profileID == selected.id,layout.folders[role] == base.appendingPathComponent(project.id.uuidString).path else { throw ProjectFailure.invalidProject }
        }
        return try SourceRenderDirectory.open(base).child(project.id.uuidString,create: true).url
    }
    func isCachePath(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return histories.contains { value in value.folders[.cache].map { path.hasPrefix(URL(fileURLWithPath: $0.displayPath).resolvingSymlinksInPath().path+"/") } == true }
    }
    func intakeCopies(_ sources: [URL],project: Project) async throws -> ([URL],[String:String]) {
        guard profile != nil || project.manifest.storageLayout != nil else { return (sources,[:]) }
        guard !busy else { throw WorkflowFailure.invalid("Wait for the current storage operation before importing.") }
        busy = true;defer { busy = false }
        let task = Task { [self] () throws -> ([URL],[String:String]) in
        var urls: [URL] = [],provenance: [String:String] = [:]
        for item in sources {
            try Task.checkCancellation()
            let source = item.resolvingSymlinksInPath().standardizedFileURL
            guard !isCachePath(source) else { throw WorkflowFailure.invalid("This is a recoverable preview proxy. Import its original recording instead.") }
            let info = try source.resourceValues(forKeys: [.isDirectoryKey,.fileSizeKey])
            guard info.isDirectory != true else { throw WorkflowFailure.invalid("With managed original copies enabled, choose individual recording files so the copy footprint is explicit. Existing folders were not changed.") }
            guard [.footage,.audio].contains(FileGroup.classify(source)) else { urls.append(source);continue }
            if let existing = project.manifest.files.first(where: { $0.ingestSourcePath == source.path }) { urls.append(URL(fileURLWithPath: existing.originalPath));continue }
            let root = try await root(for: .originals,project: project,bytes: Int64(info.fileSize ?? 0))
            let volume = try StorageVolumeProbe.observe(root)
            let selected = project.manifest.storageLayout.flatMap { layout in histories.first { $0.id == layout.profileID } } ?? profile
            guard let selected else { throw ProjectFailure.invalidProject }
            let copied = try await migration.verifiedFileCopy(source,to: root,reserveBytes: selected.workload.reserve(on: volume),label: "New recording intake; original retained")
            urls.append(copied);provenance[copied.path] = source.path
        }
        return (urls,provenance)
        }
        intakeTask = task;defer { intakeTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    var summaryWarning: String? { space.first(where: { $0.issue != nil }).flatMap { "\($0.role.label): \($0.issue!)" } }
    func createProxy(_ source: URL,project: Project) async {
        guard !busy,canLock(project) else { error = "Finish pending work and close review windows before starting this storage job.";return }
        busy = true;defer { busy = false;release() }
        await perform { [self] in
        do {
            let selected = project.manifest.storageLayout.flatMap { layout in histories.first { $0.id == layout.profileID } } ?? (project.manifest.storageLayout == nil ? profile : nil)
            guard let selected else { throw WorkflowFailure.invalid("Reconnect this project's saved storage profile first.") }
            let root = try await service.requireSpace(selected,role: .cache,bytes: StorageWorkload.gib)
            let volume = try StorageVolumeProbe.observe(root)
            _ = try await cache.createProxy(source: source,rootURL: root,reserve: selected.workload.reserve(on: volume),bitrateMbps: selected.workload.proxyMbps)
            cacheProfileID = selected.id
            message = "Source preview proxy saved. Original media and saved cuts are unchanged.";error = nil
            await refreshCache()
        } catch { self.error = error.localizedDescription }
        }
    }
    func refreshCache(project: Project? = nil) async {
        if let id = project?.manifest.storageLayout?.profileID { cacheProfileID = id }
        else if project != nil { cacheProfileID = profile?.id }
        let selected = cacheProfileID.flatMap { id in histories.first { $0.id == id } } ?? (cacheProfileID == nil ? profile : nil)
        guard let selected else { cacheItems = [];return }
        do {
            let root = try await service.resolved(selected.folders[.cache]!,role: .cache)
            cacheItems = try await cache.scan(rootURL: root,protected: protectedPaths()+(cachePreview.map { [$0] } ?? []));error = nil
        } catch { self.error = error.localizedDescription }
    }
    func trashCache(_ item: StorageCacheItem) async {
        guard !busy else { return }
        busy = true;defer { busy = false }
        await perform { [self] in
        do {
            guard let selected = histories.first(where: { $0.folders[.cache]?.managedRootID == item.record.rootID }),let grant = selected.folders[.cache] else { throw ProjectFailure.invalidProject }
            let root = try await service.resolved(grant,role: .cache)
            let receipt = try await cache.trash(item,rootURL: root,protected: protectedPaths()+(cachePreview.map { [$0] } ?? []))
            trashReceipts.append(receipt);defaults.set(try JSONEncoder().encode(trashReceipts),forKey: "ClautoStorageTrashReceipts")
            message = receipt.warning;await refreshCache()
        } catch { self.error = error.localizedDescription }
        }
    }
    func restoreCache(_ receipt: StorageCacheTrashReceipt) async {
        guard !busy else { return };busy = true;defer { busy = false }
        await perform { [self] in
        do {
            guard let selected = histories.first(where: { $0.folders[.cache]?.managedRootID == receipt.record.rootID }),let grant = selected.folders[.cache] else { throw WorkflowFailure.invalid("Reconnect the proxy's original cache profile before restoring it. Trash was retained.") }
            let root = try await service.resolved(grant,role: .cache)
            try await cache.restore(receipt,rootURL: root)
            trashReceipts.removeAll { $0.id == receipt.id };defaults.set(try JSONEncoder().encode(trashReceipts),forKey: "ClautoStorageTrashReceipts");await refreshCache()
        } catch { self.error = error.localizedDescription }
        }
    }
    func planCopy(project: Project,destination: URL,backup: Bool = false) async {
        guard !busy else { return }
        do {
            // Retain a user-selected bookmark while the reviewed copy runs.
            let grant = try await service.grant(folder: destination,role: backup ? .backups:.edits)
            destinationAccess = try StorageFolderAccess(grant)
            copyPlan = try await migration.plan(project: project,destinationParent: destination)
            copyPlan?.destinationBookmark = grant.bookmark
            journal = nil;copyPurpose = backup ? "backup":"migration";playbackURL = nil;error = nil
        } catch { self.error = error.localizedDescription }
    }
    func confirmCopy(project: Project) async {
        guard !busy,let copyPlan,copyPlan.projectID == project.id,canLock(project) else { error = "Save pending work and close review windows before confirming the copy.";return }
        busy = true;defer { busy = false;release() }
        let task = Task { [self] in do {
            let volume = try StorageVolumeProbe.observe(copyPlan.destinationParent)
            let reserve = workload.reserve(on: volume)
            journal = try await migration.copy(copyPlan,confirmedFingerprint: copyPlan.fingerprint,reserveBytes: reserve,purpose: copyPurpose) { [self] done,_ in await updateProgress(done) }
            if copyPurpose == "migration" { journal = try await migration.relink(journal!.destination) }
            message = copyPurpose == "backup" ? "Verified project backup saved. External source references are listed, not silently bundled. Original project retained." : "Copy verified. Reopen and check playback before activation. Original retained."
            error = nil
        } catch {
            self.error = error.localizedDescription
            let partial = copyPlan.destinationParent.appendingPathComponent("Clauto-copy-"+copyPlan.id.uuidString+"/Project")
            if let retained = try? await migration.load(partial) { journal = retained }
        } }
        operation = task;await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() };operation = nil
    }
    func reopenCopy() async {
        guard !busy,let journal else { return };busy = true;defer { busy = false }
        await perform { [self] in
        do {
            let (next,_,movie) = try await migration.reopen(journal.destination)
            self.journal = next;playbackURL = movie;observedPlaybackSeconds = 0;humanCheckedPlayback = false;error = nil
        } catch { self.error = error.localizedDescription }
        }
    }
    func confirmPlayback() async {
        guard !busy,let journal,let nonce = journal.playbackNonce else { return }
        do {
            if journal.playbackSource == nil { self.journal = try await migration.confirmEmptyProject(journal.destination,nonce: nonce,humanChecked: humanCheckedPlayback) }
            else { self.journal = try await migration.confirmPlayback(journal.destination,nonce: nonce,observedSeconds: observedPlaybackSeconds,humanChecked: humanCheckedPlayback) }
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
    func activateCopy(original: Project) async {
        guard !busy,let journal,journal.state == .playbackChecked,canLock(original) else { error = "Finish playback validation and pending work before activation.";return }
        busy = true;defer { busy = false;release() }
        await perform { [self] in
        do {
            let project = try await ProjectRepository().open(journal.destination)
            let checked = try await migration.activationReceipt(journal.destination)
            try await activate(project,checked);self.journal = checked
            self.journal = try await migration.markActivated(journal.destination)
            message = "Copied project activated. Original retained for rollback; no source deletion is offered.";error = nil
        } catch { self.error = error.localizedDescription }
        }
    }
    func rollbackCopy(current: Project) async {
        guard !busy,let journal,canLock(current) else { return };busy = true;defer { busy = false;release() }
        await perform { [self] in
        do {
            let next = try await migration.rollback(journal.destination)
            if current.folder == journal.destination { let original = try await ProjectRepository().open(next.plan.source);try await activate(original,next) }
            self.journal = next;message = "Original project restored. Verified and partial copies remain available; nothing was deleted.";error = nil
        } catch { self.error = error.localizedDescription }
        }
    }
    func copyMovie(project: Project,version: CutVersion) async {
        guard !busy,canLock(project) else { return };busy = true;defer { busy = false;release() }
        await perform { [self] in
        do {
            let selected = project.manifest.storageLayout.flatMap { layout in histories.first { $0.id == layout.profileID } } ?? (project.manifest.storageLayout == nil ? profile : nil)
            guard let selected,let artifact = version.artifacts.first(where: { $0.hasSuffix(".mp4") || $0.hasSuffix(".mov") }) else { throw WorkflowFailure.invalid("Choose a saved movie and confirm export storage first.") }
            let source = project.folder.appendingPathComponent("cuts/"+version.folderName+"/"+artifact)
            let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let root = try await root(for: .exports,project: project,bytes: size),volume = try StorageVolumeProbe.observe(root)
            let result = try await migration.verifiedFileCopy(source,to: root,reserveBytes: selected.workload.reserve(on: volume),label: "Saved-cut export delivery copy; original/current cut retained")
            message = "Verified export copy: "+result.path;error = nil
        } catch { self.error = error.localizedDescription }
        }
    }
    private func perform(_ work: @escaping @MainActor () async -> Void) async {
        let task = Task { await work() };operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() };operation = nil
    }
    private func updateProgress(_ value: Int64) { progressBytes = value }
    func cancel() async { operation?.cancel();intakeTask?.cancel();await advisor.cancel();await cache.cancel() }
    func flushForExit() async -> Bool {
        await cancel();if let operation { await operation.value };if let intakeTask { _ = try? await intakeTask.value }
        return !busy
    }
}
