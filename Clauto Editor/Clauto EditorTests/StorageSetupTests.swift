import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private func storageTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-storage-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
    return root.resolvingSymlinksInPath().standardizedFileURL
}
private func testDisk(_ id: String,local: Bool = true,group: String? = nil,free: Int64 = 500*StorageWorkload.gib) -> StorageVolume {
    .init(id: id,name: "Private "+id,path: "/private/"+id,capacityGroup: group ?? id,filesystem: local ? "apfs":"smbfs",totalBytes: 1000*StorageWorkload.gib,availableBytes: free,importantUsageBytes: nil,local: local,internalDevice: local,medium: local ? .ssd:.unknown,writable: true,available: true,observed: Date(),performance: .estimate(local: local,medium: local ? .ssd:.unknown))
}
private func smallWorkload() -> StorageWorkload { .init(originalsGiB: 0,footageHours: 0,finishedMinutes: 0,reserveFraction: 0.01,minimumReserveGiB: 1) }
private func fixtureStorageService(_ root: URL) -> StorageWorkspaceService {
    StorageWorkspaceService { url in
        var observed = try StorageVolumeProbe.observe(url)
        // Only this disposable fixture's capacity is synthetic. Real bookmark
        // volume IDs, identities and filesystem behavior remain checked.
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path == root.path || path.hasPrefix(root.path+"/") {
            observed.totalBytes = 100*StorageWorkload.gib;observed.availableBytes = 90*StorageWorkload.gib
            observed.importantUsageBytes = nil
        }
        return observed
    }
}
private func preparedProfile(_ root: URL,service: StorageWorkspaceService? = nil) async throws -> StorageProfile {
    let service = service ?? fixtureStorageService(root)
    let volume = try StorageVolumeProbe.observe(root)
    let advice = StorageAdvice(source: .localRules,choices: Dictionary(uniqueKeysWithValues: StorageRole.allCases.map { ($0,volume.id) }),explanation: "Synthetic test",warnings: [],responseSHA256: nil)
    var folders: [StorageRole:StorageFolderGrant] = [:]
    for role in StorageRole.allCases { folders[role] = try await service.grant(folder: root,role: role) }
    let profile = StorageProfile(id: UUID(),confirmed: Date(),workload: smallWorkload(),advice: advice,folders: folders)
    _ = try await service.prepare(profile)
    return try await service.boundProfile(profile)
}
private func nativeFixture(_ root: URL) async throws -> (Project,URL) {
    let target = root.appendingPathComponent("Target")
    try FileManager.default.createDirectory(at: target,withIntermediateDirectories: false)
    return (try await ProjectRepository().create(name: "Synthetic",root: root.appendingPathComponent("Source"),engine: root),target)
}
private func fileBytes(_ root: URL) throws -> [String:Data] {
    var result: [String:Data] = [:]
    for case let url as URL in FileManager.default.enumerator(at: root,includingPropertiesForKeys: [.isRegularFileKey])! {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,!url.path.hasSuffix("project-mutation.lock") {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
    }
    return result
}

struct StoragePlanningTests {
    @Test func recommendsFromFactsWithoutInventingMeasuredSpeed() throws {
        let disks = [testDisk("ssd"),testDisk("nas",local: false),testDisk("archive",local: false)]
        let advice = try StorageRecommendation.local(volumes: disks,workload: .init())
        #expect(advice.source == .localRules && advice.choices[.edits] == "ssd" && advice.choices[.cache] == "ssd")
        #expect(advice.choices[.backups] != advice.choices[.originals] && advice.choices[.backups] != advice.choices[.edits])
        try StorageRecommendation.validate(advice,volumes: disks,workload: .init())
        #expect(disks.allSatisfy { $0.performance.basis == .estimated && $0.performance.readMBps == nil && $0.performance.measuredAt == nil })
    }
    @Test func offlineReadOnlyAndInsufficientSpaceNeverSilentlyFit() throws {
        var disk = testDisk("offline");disk.available = false
        var readonly = testDisk("readonly");readonly.writable = false
        let tiny = testDisk("tiny",free: 1024)
        let plan = try StorageRecommendation.local(volumes: [disk,readonly,tiny],workload: .init())
        #expect(plan.choices.isEmpty && plan.warnings.count == 5)
        #expect(throws: (any Error).self) { try StorageRecommendation.validate(plan,volumes: [disk,readonly,tiny],workload: .init()) }
    }
    @Test func sharedCapacityIsCountedOnceAcrossDistinctVolumeIDs() throws {
        let disks = [testDisk("a",group: "pool",free: 120*StorageWorkload.gib),testDisk("b",group: "pool",free: 120*StorageWorkload.gib)]
        let choices = Dictionary(uniqueKeysWithValues: StorageRole.allCases.enumerated().map { ($0.element,$0.offset % 2 == 0 ? "a":"b") })
        let plan = StorageAdvice(source: .localRules,choices: choices,explanation: "",warnings: [],responseSHA256: nil)
        #expect(throws: (any Error).self) { try StorageRecommendation.validate(plan,volumes: disks,workload: .init()) }
    }
    @Test func nonfiniteFormValuesDoNotTrapAndCannotBeConfirmed() {
        var workload = smallWorkload();workload.originalsGiB = .nan
        #expect(workload.bytes(for: .originals) == 0)
        #expect(throws: (any Error).self) { try workload.validate() }
        workload.reserveFraction = .infinity
        #expect(workload.reserve(on: testDisk("a")) == Int64.max / 4)
    }
    @Test func nestedRolePathsAndMismatchedDeviceChoicesRefuse() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        var profile = try await preparedProfile(root)
        profile.folders[.backups] = profile.folders[.edits]
        #expect(throws: (any Error).self) { try profile.validate() }
        profile = try await preparedProfile(root);profile.advice.choices[.originals] = "other device"
        #expect(throws: (any Error).self) { try profile.validate() }
    }
    @Test func replacedOwnedFolderFailsClosedAndMonitorRetainsPath() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let service = fixtureStorageService(root),profile = try await preparedProfile(root,service: service)
        let grant = try #require(profile.folders[.cache]),cache = URL(fileURLWithPath: grant.displayPath)
        try FileManager.default.moveItem(at: cache,to: cache.appendingPathExtension("retained"))
        try FileManager.default.createDirectory(at: cache,withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { _ = try await service.requireSpace(profile,role: .cache,bytes: 0) }
        let states = await service.monitor(profile)
        #expect(states.first { $0.role == .cache }?.issue != nil)
        #expect(states.first { $0.role == .cache }?.path == grant.displayPath)
    }
}

struct StorageMigrationTests {
    @Test func completeEmptyProjectCopyActivationAndRollbackRetainSourceBytes() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let (project,target) = try await nativeFixture(root),service = StorageMigrationService()
        try Data("User file with spaces and accents".utf8).write(to: project.folder.appendingPathComponent("notes/édit review.txt"))
        let before = try fileBytes(project.folder),plan = try await service.plan(project: project,destinationParent: target)
        let copied = try await service.copy(plan,confirmedFingerprint: plan.fingerprint,reserveBytes: 0)
        #expect(copied.state == .copyVerified && copied.copiedBytes == plan.totalBytes)
        #expect(!FileManager.default.fileExists(atPath: copied.destination.appendingPathComponent("storage-migration.json").path))
        _ = try await service.relink(copied.destination)
        let (opened,loaded,movie) = try await service.reopen(copied.destination)
        #expect(loaded.id == project.id && movie == nil && opened.state == .reopened)
        await #expect(throws: (any Error).self) { _ = try await service.activationReceipt(copied.destination) }
        await #expect(throws: (any Error).self) { _ = try await service.confirmEmptyProject(copied.destination,nonce: UUID(),humanChecked: true) }
        _ = try await service.confirmEmptyProject(copied.destination,nonce: #require(opened.playbackNonce),humanChecked: true)
        #expect(try await service.activationReceipt(copied.destination).state == .activated)
        #expect(try await service.load(copied.destination).state == .playbackChecked)
        _ = try await service.markActivated(copied.destination)
        #expect(try await service.rollback(copied.destination).state == .rolledBack)
        #expect(try fileBytes(project.folder) == before)
        #expect(FileManager.default.fileExists(atPath: copied.destination.path))
    }
    @Test func reviewedSourceChangesAndDestinationReplacementRefuseBeforeCopy() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let (project,target) = try await nativeFixture(root),service = StorageMigrationService()
        let plan = try await service.plan(project: project,destinationParent: target)
        try Data("changed".utf8).write(to: project.folder.appendingPathComponent("notes/new.txt"))
        await #expect(throws: (any Error).self) { _ = try await service.copy(plan,confirmedFingerprint: plan.fingerprint,reserveBytes: 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let fresh = try await service.plan(project: project,destinationParent: target)
        try FileManager.default.moveItem(at: target,to: target.appendingPathExtension("retained"))
        try FileManager.default.createDirectory(at: target,withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { _ = try await service.copy(fresh,confirmedFingerprint: fresh.fingerprint,reserveBytes: 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @Test func fingerprintBindsExactDestinationAndExpiredApprovalRefuses() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let (project,target) = try await nativeFixture(root),service = StorageMigrationService()
        let plan = try await service.plan(project: project,destinationParent: target)
        var changed = plan;changed.destinationParent = root
        #expect(plan.fingerprint != changed.fingerprint)
        await #expect(throws: (any Error).self) { _ = try await service.copy(changed,confirmedFingerprint: plan.fingerprint,reserveBytes: 0) }
        changed = plan;changed.created = .distantPast
        await #expect(throws: (any Error).self) { _ = try await service.copy(changed,confirmedFingerprint: changed.fingerprint,reserveBytes: 0) }
    }
    @Test func sealedEscapedJSONReferenceBlocksActivationWithoutRewritingEvidence() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let (project,target) = try await nativeFixture(root),service = StorageMigrationService()
        let path = project.folder.appendingPathComponent("notes/sealed.json")
        let evidence = try JSONSerialization.data(withJSONObject: ["nested":["old":project.folder.path+"/cuts/v001"]])
        try evidence.write(to: path)
        let plan = try await service.plan(project: project,destinationParent: target)
        let copied = try await service.copy(plan,confirmedFingerprint: plan.fingerprint,reserveBytes: 0)
        let linked = try await service.relink(copied.destination)
        #expect(linked.state == .needsRelink && linked.unresolvedReferences == ["notes/sealed.json"])
        #expect(try Data(contentsOf: copied.destination.appendingPathComponent("notes/sealed.json")) == evidence)
        await #expect(throws: (any Error).self) { _ = try await service.reopen(copied.destination) }
    }
    @Test func alteredCopiedPayloadRefusesAndSourceRemainsUntouched() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let (project,target) = try await nativeFixture(root),service = StorageMigrationService()
        let before = try fileBytes(project.folder),plan = try await service.plan(project: project,destinationParent: target)
        let copied = try await service.copy(plan,confirmedFingerprint: plan.fingerprint,reserveBytes: 0)
        try Data("tampered".utf8).write(to: copied.destination.appendingPathComponent("brief.md"))
        await #expect(throws: (any Error).self) { _ = try await service.relink(copied.destination) }
        #expect(try fileBytes(project.folder) == before)
    }
    @Test func unsupportedDatabasesAreHeldBeforeAnyCopy() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let (project,target) = try await nativeFixture(root),service = StorageMigrationService()
        try Data("database fixture".utf8).write(to: project.folder.appendingPathComponent("notes/active.sqlite"))
        await #expect(throws: (any Error).self) { _ = try await service.plan(project: project,destinationParent: target) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @Test func cancelledCopyPersistsInterruptedJournalAndRetainsPartialEvidence() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let (project,target) = try await nativeFixture(root),service = StorageMigrationService()
        let before = try fileBytes(project.folder),plan = try await service.plan(project: project,destinationParent: target)
        let task = Task {
            try await service.copy(plan,confirmedFingerprint: plan.fingerprint,reserveBytes: 0) { done,_ in
                if done > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let destination = target.appendingPathComponent("Clauto-copy-"+plan.id.uuidString+"/Project")
        let journal = try await service.load(destination)
        #expect(journal.state == .interrupted && journal.failure != nil && journal.sourceRetained)
        #expect(try fileBytes(project.folder) == before)
    }
    @Test func originalCopyProvenanceAndProjectLayoutUseExistingProjectContract() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let service = fixtureStorageService(root),profile = try await preparedProfile(root,service: service)
        var roots: [StorageRole:URL] = [:]
        for role in StorageRole.allCases { roots[role] = try await service.resolved(profile.folders[role]!,role: role) }
        let repository = ProjectRepository(),project = try await repository.create(name: "Managed",root: roots[.edits]!,engine: root,storageProfileID: profile.id,storageRoots: roots)
        #expect(project.manifest.storageLayout?.folders[.edits] == project.folder.path)
        let original = root.appendingPathComponent("recording.mov"),bytes = Data("synthetic recording bytes, never decoded".utf8)
        try bytes.write(to: original)
        let originals = URL(fileURLWithPath: project.manifest.storageLayout!.folders[.originals]!)
        let copied = try await StorageMigrationService().verifiedFileCopy(original,to: originals,reserveBytes: 0,label: "fixture")
        let added = try await repository.add([copied],to: project,ingestProvenance: [copied.path:original.path])
        #expect(added.manifest.files.first?.ingestSourcePath == original.path)
        #expect(try Data(contentsOf: original) == bytes && Data(contentsOf: copied) == bytes)
        #expect(try await repository.open(project.folder).id == project.id)
    }
}

private struct StorageCacheFixture {
    var root: URL
    var folder: URL
    var record: StorageCacheRecord
    static func make(_ base: URL) async throws -> Self {
        let root = base.appendingPathComponent("cache");try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
        let handle = try SourceRenderDirectory.open(root),marker = try await StorageWorkspaceService().managedRoot(handle,role: .cache,create: true)
        let id = UUID(),folder = try handle.child("items",create: true).child(id.uuidString,create: true)
        let bytes = Data("synthetic registered payload".utf8)
        try folder.writeNew(bytes,name: "proxy.mp4")
        let originalBytes = Data("synthetic unchanged original".utf8)
        try originalBytes.write(to: base.appendingPathComponent("original.mov"))
        let record = StorageCacheRecord(id: id,rootID: marker.id,source: base.appendingPathComponent("original.mov"),sourceSHA256: TranscriptSourceMap.sha(originalBytes),bytes: Int64(bytes.count),payloadSHA256: TranscriptSourceMap.sha(bytes),created: Date())
        try folder.writeNew(CreativeAssetFiles.encoder().encode(record),name: "cache-record.json")
        return .init(root: root,folder: folder.url,record: record)
    }
}
struct StorageCacheTests {
    @Test func onlyRegisteredUnchangedExactProxyFoldersQualify() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let f = try await StorageCacheFixture.make(root),unknown = StorageCacheService(defaults: nil)
        #expect(try await unknown.scan(rootURL: f.root,protected: []).isEmpty)
        let service = StorageCacheService(defaults: nil,trustedRecords: [f.record])
        #expect(try await service.scan(rootURL: f.root,protected: []).count == 1)
        try Data("important unregistered file".utf8).write(to: f.folder.appendingPathComponent("keep.mov"))
        #expect(try await service.scan(rootURL: f.root,protected: []).isEmpty)
    }
    @Test func activeReferencePreventsTrashAndInjectedRecoverableRoundtripWorks() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let f = try await StorageCacheFixture.make(root),service = StorageCacheService(defaults: nil,trustedRecords: [f.record])
        let item = try #require(try await service.scan(rootURL: f.root,protected: []).first)
        let protected = try #require(try await service.scan(rootURL: f.root,protected: [item.movie]).first)
        #expect(protected.protectedReason != nil)
        await #expect(throws: (any Error).self) { _ = try await service.trash(item,rootURL: f.root,protected: [item.movie],move: { _ in throw ProjectFailure.invalidProject }) }
        let trash = root.appendingPathComponent("recoverable-test-trash")
        let receipt = try await service.trash(item,rootURL: f.root,protected: [],move: { url in try FileManager.default.moveItem(at: url,to: trash);return trash })
        #expect(receipt.warning.contains("not a guaranteed reclaim") && FileManager.default.fileExists(atPath: trash.path))
        try await service.restore(receipt,rootURL: f.root)
        #expect(try await service.scan(rootURL: f.root,protected: []).count == 1)
        await #expect(throws: (any Error).self) { try await service.restore(receipt,rootURL: f.root) }
    }
    @Test func modifiedPayloadIsExcludedRatherThanDeleted() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let f = try await StorageCacheFixture.make(root),service = StorageCacheService(defaults: nil,trustedRecords: [f.record])
        try Data("tamper".utf8).write(to: f.folder.appendingPathComponent("proxy.mp4"))
        #expect(try await service.scan(rootURL: f.root,protected: []).isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.folder.path))
    }
}

private actor UnavailableStorageAdvisor: StorageAdvising {
    func recommend(volumes: [StorageVolume],workload: StorageWorkload) throws -> StorageAdvice { throw ClaudeClientFailure.missing }
    func cancel() {}
}
@MainActor struct StorageSetupControllerTests {
    @Test func reviewIsWriteFreeAndChangesInvalidateApprovalBeforeFutureOnlyConfirmation() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let controller = StorageSetupController(defaults: defaults,service: fixtureStorageService(root),cache: .init(defaults: nil),advisor: UnavailableStorageAdvisor())
        controller.workload = smallWorkload();await controller.recommend(useConnectedAI: false)
        for role in StorageRole.allCases { await controller.choose(role: role,folder: root) }
        await controller.review()
        #expect(controller.error == nil)
        #expect(controller.reviewedProfile != nil && controller.profile == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        controller.workload.finishedMinutes = 1
        #expect(controller.reviewedProfile == nil)
        #expect(await controller.confirmProfile() == nil)
        controller.workload = smallWorkload();await controller.review()
        let editRoot = await controller.confirmProfile()
        #expect(editRoot != nil && controller.profile != nil && defaults.data(forKey: "ClautoStorageProfiles") != nil)
        let priorID = controller.profile?.id
        controller.workload.finishedMinutes = 1;await controller.review()
        #expect(controller.reviewedProfile?.id != priorID && controller.profile?.id == priorID)
        #expect(controller.message?.contains("Existing projects") == true)
    }
    @Test func unavailableAIUsesExplicitlyLabeledSafeLocalFallback() async throws {
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let controller = StorageSetupController(defaults: defaults,cache: .init(defaults: nil),advisor: UnavailableStorageAdvisor())
        controller.workload = smallWorkload();await controller.recommend()
        #expect(controller.advice?.source == .localRules)
        #expect(controller.message?.contains("local rules") == true)
        #expect(controller.profile == nil && defaults.data(forKey: "ClautoStorageProfiles") == nil)
    }
}

private actor StorageAdvisorCommandFixture: CommandRunning {
    var commands: [ProcessCommand] = []
    func run(_ command: ProcessCommand,onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        commands.append(command)
        if command.arguments == ["--help"] { return .init(exitCode: 0,output: ClaudeClientContract.requiredFlags.joined(separator: " "),error: "",cancelled: false) }
        if command.arguments == ["auth","status","--json"] { return .init(exitCode: 0,output: #"{"authMethod":"claude.ai"}"#,error: "",cancelled: false) }
        guard command.arguments.contains("--print"),let index = command.arguments.firstIndex(of: "--session-id") else { throw ClaudeFailure.incomplete }
        let reply = #"{"choices":{"edits":"disk1","originals":"disk2","cache":"disk1","exports":"disk1","backups":"disk2"},"explanation":"Synthetic capacity suggestion. Performance is estimated.","warnings":["Backup server independence unverified."]}"#
        for object: [String:Any] in [["type":"system","subtype":"init","session_id":command.arguments[index+1]],["type":"result","subtype":"success","is_error":false,"result":reply]] {
            await onLine?(.init(text: String(decoding: try JSONSerialization.data(withJSONObject: object),as: UTF8.self),isError: false))
        }
        return .init(exitCode: 0,output: "",error: "",cancelled: false)
    }
    func cancel() {}
}
extension StoragePlanningTests {
    @Test func syntheticConnectedAIContractSendsAnonymousFactsAndNoTools() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("synthetic-client-never-executed")
        try Data("fixture, runner injected".utf8).write(to: executable)
        let runner = StorageAdvisorCommandFixture(),advisor = ConnectedStorageAdvisor(runner: runner,locate: { executable })
        let advice = try await advisor.recommend(volumes: [testDisk("SECRETSSD"),testDisk("SECRETNAS",local: false)],workload: smallWorkload())
        #expect(advice.source == .connectedClaude && advice.choices[.edits] == "SECRETSSD")
        let commands = await runner.commands,turn = try #require(commands.first { $0.arguments.contains("--print") })
        let prompt = try #require(turn.arguments.last)
        #expect(!prompt.contains("SECRET") && !prompt.contains("/private/") && !prompt.contains(root.path))
        #expect(prompt.contains("performanceBasis") && prompt.contains("estimatedBytesByRole"))
        #expect(turn.arguments.contains("--restricted") && turn.arguments.contains("--no-chrome"))
        let tools = try #require(turn.arguments.firstIndex(of: "--tools"));#expect(turn.arguments[tools+1].isEmpty)
        #expect(!commands.contains { $0.arguments.contains("login") })
    }
}
extension StorageCacheTests {
    @Test func actualTinyProxyIsVerifiedAndOriginalBytesRemainIdentical() async throws {
        guard let ffmpeg = ProcessRunner.executable("ffmpeg") else { Issue.record("Declared local ffmpeg is missing; actual proxy verification could not run.");return }
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("test source.mp4"),runner = ProcessRunner()
        let generated = try await runner.run(.init(executable: ffmpeg,arguments: ["-nostdin","-v","error","-f","lavfi","-i","testsrc2=size=128x72:rate=12","-t","0.5","-threads","1","-c:v","libx264",source.path]))
        #expect(generated.succeeded)
        let before = try Data(contentsOf: source),profile = try await preparedProfile(root),cacheRoot = URL(fileURLWithPath: profile.folders[.cache]!.displayPath)
        let service = StorageCacheService(defaults: nil),item = try await service.createProxy(source: source,rootURL: cacheRoot,reserve: 0)
        #expect(item.record.sourceSHA256 == TranscriptSourceMap.sha(before))
        #expect(try Data(contentsOf: source) == before)
        #expect(try await service.scan(rootURL: cacheRoot,protected: []).map(\.id) == [item.id])
        let decoded = try await runner.run(.init(executable: ffmpeg,arguments: ["-nostdin","-v","error","-i",item.movie.path,"-f","null","-"]))
        #expect(decoded.succeeded)
    }
}

#if !canImport(ClautoCore)
@MainActor @Suite(.serialized) struct StorageSetupNativeStoreTests {
    @Test func confirmedFutureLocationsPreserveLegacyProjectAndIntegratedNavigation() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let legacyRoot = root.appendingPathComponent("Legacy"),repository = ProjectRepository()
        let legacy = try await repository.create(name: "Existing Pizza",root: legacyRoot,engine: root)
        let before = try fileBytes(legacy.folder)
        defaults.set(legacyRoot.path,forKey: "ClautoProjectsRoot");defaults.set(root.path,forKey: "ClautoEngineRoot");defaults.set([legacy.folder.path],forKey: "ClautoRecentProjects")
        let store = EditorStore(defaults: defaults,storageService: fixtureStorageService(root));await store.restore()
        store.rememberProjectTab("Script")
        let controller = store.scriptWorkspace(for: legacy)
        let storage = store.storage;storage.workload = smallWorkload();await storage.recommend(useConnectedAI: false)
        let chosen = root.appendingPathComponent("Chosen");try FileManager.default.createDirectory(at: chosen,withIntermediateDirectories: false)
        for role in StorageRole.allCases { await storage.choose(role: role,folder: chosen) }
        await storage.review()
        try #require(storage.reviewedProfile != nil,Comment(rawValue: storage.error ?? "Storage review did not complete."))
        let editRoot = try #require(await storage.confirmProfile(),Comment(rawValue: storage.error ?? "Storage profile confirmation did not complete."));store.setFolders(projects: editRoot)
        #expect(await store.create("New managed project"))
        let managed = try #require(store.selected)
        #expect(managed.manifest.storageLayout?.profileID == storage.profile?.id)
        #expect(managed.folder.deletingLastPathComponent().path == editRoot.path)
        #expect(Set(store.projects.map(\.id)) == [legacy.id,managed.id])
        store.selectedID = legacy.id
        #expect(store.initialProjectTab == "Script" && store.scriptWorkspace(for: legacy) === controller)
        #expect(try fileBytes(legacy.folder) == before)
        #expect(legacy.manifest.storageLayout == nil)
        #expect(await store.flushReviewWorkForExit())
    }
    @Test func verifiedMoveAndRollbackUseOneCatalogIdentityAndPreserveOtherProjects() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let (project,target) = try await nativeFixture(root),other = try await ProjectRepository().create(name: "Other",root: project.folder.deletingLastPathComponent(),engine: root)
        defaults.set(project.folder.deletingLastPathComponent().path,forKey: "ClautoProjectsRoot");defaults.set([project.folder.path,other.folder.path],forKey: "ClautoRecentProjects")
        let store = EditorStore(defaults: defaults);await store.restore();store.selectedID = project.id
        let before = try fileBytes(project.folder),otherBefore = try fileBytes(other.folder),originalController = store.scriptWorkspace(for: project)
        let storage = store.storage
        storage.workload = smallWorkload() // Synthetic local copy must fit this Mac's real reserve.
        await storage.planCopy(project: project,destination: target)
        #expect(storage.copyPlan != nil && storage.journal == nil)
        store.runningProjectID = project.id;await storage.confirmCopy(project: project)
        #expect(storage.journal == nil)
        store.runningProjectID = nil
        let soundOwner = UUID();store.registerSoundWorkspace(soundOwner,projectID: project.id)
        await storage.confirmCopy(project: project);#expect(storage.journal == nil)
        store.unregisterSoundWorkspace(soundOwner);await storage.confirmCopy(project: project)
        try #require(storage.journal?.state == .copyVerified,Comment(rawValue: storage.error ?? "The copy did not reach verification."))
        await storage.reopenCopy();storage.humanCheckedPlayback = true;await storage.confirmPlayback()
        #expect(storage.journal?.state == .playbackChecked)
        await storage.activateCopy(original: project)
        let moved = try #require(store.selected)
        #expect(storage.error == nil && storage.journal?.state == .activated)
        #expect(moved.id == project.id && moved.folder.path != project.folder.path)
        #expect(store.projects.count == 2 && store.scriptWorkspace(for: moved) !== originalController)
        #expect(store.projectBookmarks.first { $0.projectID == project.id }?.path == moved.folder.path)
        await storage.rollbackCopy(current: moved)
        #expect(storage.error == nil && store.selected?.folder.path == project.folder.path)
        #expect(storage.journal?.state == .rolledBack)
        #expect(try fileBytes(project.folder) == before && fileBytes(other.folder) == otherBefore)
        #expect(Set(store.projects.map(\.id)) == [project.id,other.id])
        #expect(await store.flushReviewWorkForExit())
    }
}
#endif

private actor HoldingStorageAdvisor: StorageAdvising {
    private var waiter: CheckedContinuation<StorageAdvice,Error>?
    private(set) var started = false
    func recommend(volumes: [StorageVolume],workload: StorageWorkload) async throws -> StorageAdvice {
        started = true
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel() { waiter?.resume(throwing: CancellationError());waiter = nil }
}
extension StorageSetupControllerTests {
    @Test func cancelJoinsOwnedRecommendationAndNeverConfirmsPartialAdvice() async throws {
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let advisor = HoldingStorageAdvisor(),controller = StorageSetupController(defaults: defaults,cache: .init(defaults: nil),advisor: advisor)
        controller.workload = smallWorkload()
        let pending = Task { await controller.recommend() }
        for _ in 0..<500 { if await advisor.started { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(await advisor.started && controller.busy)
        await controller.cancel();await pending.value
        #expect(!controller.busy && controller.profile == nil && controller.reviewedProfile == nil)
        #expect(await controller.flushForExit())
        #expect(defaults.data(forKey: "ClautoStorageProfiles") == nil)
    }
    @Test func newRunRefusesReplacedConfiguredCacheWithoutFallingBack() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let profile = try await preparedProfile(root),service = StorageWorkspaceService()
        defaults.set(try JSONEncoder().encode([profile]),forKey: "ClautoStorageProfiles");defaults.set(profile.id.uuidString,forKey: "ClautoActiveStorageProfile")
        var roots: [StorageRole:URL] = [:]
        for role in StorageRole.allCases { roots[role] = try await service.resolved(profile.folders[role]!,role: role) }
        let project = try await ProjectRepository().create(name: "Run storage",root: roots[.edits]!,engine: root,storageProfileID: profile.id,storageRoots: roots)
        let controller = StorageSetupController(defaults: defaults,cache: .init(defaults: nil),advisor: UnavailableStorageAdvisor())
        try await controller.validateProjectWrites(project)
        let cache = roots[.cache]!
        try FileManager.default.moveItem(at: cache,to: cache.appendingPathExtension("old-retained"))
        try FileManager.default.createDirectory(at: cache,withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await controller.validateProjectWrites(project) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }
}

extension StorageCacheTests {
    @Test func missingOrChangedOriginalPreventsCleanupOfItsLastProxy() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let f = try await StorageCacheFixture.make(root),service = StorageCacheService(defaults: nil,trustedRecords: [f.record])
        let item = try #require(try await service.scan(rootURL: f.root,protected: []).first)
        try Data("changed recording".utf8).write(to: f.record.source)
        await #expect(throws: (any Error).self) { _ = try await service.trash(item,rootURL: f.root,protected: [],move: { _ in Issue.record("Must not move an irreplaceable proxy");throw ProjectFailure.invalidProject }) }
        try FileManager.default.removeItem(at: f.record.source)
        await #expect(throws: (any Error).self) { _ = try await service.trash(item,rootURL: f.root,protected: [],move: { _ in Issue.record("Must not move an irreplaceable proxy");throw ProjectFailure.invalidProject }) }
        #expect(FileManager.default.fileExists(atPath: item.movie.path))
    }
}

/// A delayed bookmark result exercises main-actor reentrancy without blocking a
/// filesystem probe or touching a live project. Production still uses service.grant.
private actor HeldStorageFolderGrant {
    let grants: [StorageRole:StorageFolderGrant]
    private var holding = false
    private var waiter: CheckedContinuation<StorageFolderGrant,Error>?
    private var pendingRole: StorageRole?
    private(set) var started = false
    init(_ grants: [StorageRole:StorageFolderGrant]) { self.grants = grants }
    func hold() { holding = true }
    func resolve(_ role: StorageRole) async throws -> StorageFolderGrant {
        guard let grant = grants[role] else { throw ProjectFailure.invalidProject }
        guard holding else { return grant }
        started = true;pendingRole = role
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func finish() {
        guard let role = pendingRole,let grant = grants[role] else { return }
        waiter?.resume(returning: grant);waiter = nil;pendingRole = nil;holding = false
    }
}
private func heldStorageGrants(_ root: URL,service: StorageWorkspaceService) async throws -> HeldStorageFolderGrant {
    var grants: [StorageRole:StorageFolderGrant] = [:]
    for role in StorageRole.allCases { grants[role] = try await service.grant(folder: root,role: role) }
    return HeldStorageFolderGrant(grants)
}
extension StorageSetupControllerTests {
    @Test func pendingFolderChoiceImmediatelyInvalidatesReviewAndCannotBeConfirmed() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let service = fixtureStorageService(root),gate = try await heldStorageGrants(root,service: service)
        let controller = StorageSetupController(defaults: defaults,service: service,cache: .init(defaults: nil),advisor: UnavailableStorageAdvisor(),folderGrant: { _,role in try await gate.resolve(role) })
        controller.workload = smallWorkload();await controller.recommend(useConnectedAI: false)
        for role in StorageRole.allCases { await controller.choose(role: role,folder: root) }
        await controller.review();let oldReview = try #require(controller.reviewedProfile)
        await gate.hold()
        let pending = Task { await controller.choose(role: .edits,folder: root) }
        for _ in 0..<500 { if await gate.started { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(controller.reviewedProfile == nil && controller.choosingFolderRoles == [.edits])
        await controller.review();#expect(controller.reviewedProfile == nil)
        #expect(await controller.confirmProfile() == nil)
        #expect(defaults.data(forKey: "ClautoStorageProfiles") == nil)
        await gate.finish();await pending.value
        #expect(controller.choosingFolderRoles.isEmpty && controller.profile == nil)
        await controller.review();#expect(controller.reviewedProfile?.id != oldReview.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func delayedFolderChoiceCannotOverwriteANewerDriveChoice() async throws {
        let root = try storageTestRoot();defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let service = fixtureStorageService(root),gate = try await heldStorageGrants(root,service: service)
        let controller = StorageSetupController(defaults: defaults,service: service,cache: .init(defaults: nil),advisor: UnavailableStorageAdvisor(),folderGrant: { _,role in try await gate.resolve(role) })
        controller.workload = smallWorkload();await controller.recommend(useConnectedAI: false);await gate.hold()
        let pending = Task { await controller.choose(role: .cache,folder: root) }
        for _ in 0..<500 { if await gate.started { break };try await Task.sleep(for: .milliseconds(2)) }
        controller.selectVolume("new-explicit-drive-choice",role: .cache)
        await gate.finish();await pending.value
        #expect(controller.advice?.choices[.cache] == "new-explicit-drive-choice")
        #expect(controller.folders[.cache] == nil && controller.choosingFolderRoles.isEmpty)
        #expect(controller.reviewedProfile == nil && controller.profile == nil)
        #expect(defaults.data(forKey: "ClautoStorageProfiles") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
#if !canImport(ClautoCore)
extension StorageSetupNativeStoreTests {
    @Test func unsavedSoundWorkspaceBlocksOrdinaryQuitUntilSavedOrExplicitlyDiscarded() async throws {
        final class Draft { var unsaved = true }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorStore(defaults: defaults),owner = UUID(),draft = Draft()
        store.registerSoundWorkspace(owner,projectID: UUID(),hasUnsaved: { draft.unsaved })
        #expect(store.hasUnsavedSoundEdits && store.hasPendingReviewWork)
        #expect(await store.flushReviewWorkForExit() == false)
        #expect(store.hasUnsavedSoundEdits && draft.unsaved)
        draft.unsaved = false
        #expect(await store.flushReviewWorkForExit())
        #expect(!store.hasUnsavedSoundEdits)
        draft.unsaved = true;store.unregisterSoundWorkspace(owner)
        #expect(!store.hasUnsavedSoundEdits)
    }
}
#endif
