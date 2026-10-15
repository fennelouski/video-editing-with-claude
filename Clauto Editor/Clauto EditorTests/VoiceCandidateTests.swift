import Foundation
import Darwin
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor CancellablePreviewRunner: CommandRunning {
    var started = false
    private var cancelled = false
    func run(_ command: ProcessCommand,onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        started = true
        await onLine?(.init(text: "{\"phase\":\"render_fragment\"}",isError: false))
        while !cancelled { try? await Task.sleep(for: .milliseconds(5)); await Task.yield() }
        return .init(exitCode: 130,output: "",error: "Synthetic worker cancelled",cancelled: true)
    }
    func cancel() { cancelled = true }
}

struct VoiceCandidateTests {
    private struct Fixture { let root: URL; let project: Project; let target: VoiceReviewTarget; let repository: VoiceReviewRepository; let engine: URL }
    private func fixture(root requested: URL? = nil) async throws -> Fixture {
        let root = requested ?? FileManager.default.temporaryDirectory.appendingPathComponent("clauto-master-candidate-"+UUID().uuidString)
        let engine = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try await ProjectRepository().create(name: "Synthetic watched-master voice QA",root: root,engine: engine,engineVersion: "synthetic")
        let base = project.folder.appendingPathComponent("cuts/v001")
        for name in ["exports","inputs/script","plan"] { try FileManager.default.createDirectory(at: base.appendingPathComponent(name),withIntermediateDirectories: true) }
        let movie = base.appendingPathComponent("exports/review.mp4")
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),arguments: ["-v","error","-nostdin","-n","-f","lavfi","-i","color=c=red:s=160x90:r=24000/1001,drawbox=color=green:t=fill:enable='between(n,12,23)',drawbox=color=blue:t=fill:enable='gte(n,24)'","-f","lavfi","-i","sine=frequency=440:sample_rate=48000","-vf","setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709","-frames:v","36","-af","atrim=end_sample=72072","-c:v","libx264","-bf","2","-crf","0","-pix_fmt","yuv420p","-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709","-c:a","aac","-ac","2",movie.path],timeout: .seconds(30)),onLine: nil)
        guard result.succeeded else { throw WorkflowFailure.invalid(result.error) }
        let xml = Data("<fcpxml version=\"1.13\"><resources/><library><event><project><sequence duration=\"3003/2000s\"><spine/></sequence></project></event></library></fcpxml>".utf8)
        try xml.write(to: base.appendingPathComponent("exports/cut.fcpxml"))
        for name in ["inputs/brief.md","inputs/script/approved.md","plan/cut.plan.json","clauto-version.json"] { try Data(("Synthetic-only "+name).utf8).write(to: base.appendingPathComponent(name)) }
        func inspect(_ path: String) throws -> VoiceArtifact { try VoiceReviewProvenance.inspect("cuts/v001/"+path,project: project) }
        let target = try VoiceReviewTarget(id: UUID(),projectID: project.id,versionID: UUID(),versionNumber: 1,versionMetadataSHA256: inspect("clauto-version.json").sha256,timeline: inspect("exports/cut.fcpxml"),preview: inspect("exports/review.mp4"),approvedPlanSHA256: inspect("plan/cut.plan.json").sha256,approvedPlanPath: "cuts/v001/plan/cut.plan.json",approvedScriptSHA256: inspect("inputs/script/approved.md").sha256,approvedScriptPath: "cuts/v001/inputs/script/approved.md",approvedBriefSHA256: inspect("inputs/brief.md").sha256,engineVersion: "synthetic",duration: 36*1001/24000)
        let repository = try VoiceReviewRepository(project: project); _ = try await repository.register(target)
        return .init(root: root,project: project,target: target,repository: repository,engine: engine)
    }
    private func note(_ f: Fixture, action: VoiceRangeAction, start: Int, end: Int) async throws -> VoiceReviewDocument {
        try await f.repository.addTyped(text: action == .protect ? "Keep this range" : "Remove this range",action: action,anchor: .init(targetID: f.target.id,seconds: Double(start*1001)/24000,endSeconds: Double(end*1001)/24000))
    }
    private func prepare(_ f: Fixture) async throws -> VoiceRevisionCandidate {
        try await VoiceCandidateWorker(repository: f.repository).drain()
        let id = try #require(try await f.repository.load().candidates.last?.id)
        _ = try await f.repository.prepareEditPlan(id)
        return try #require(try await f.repository.load().candidates.last)
    }
    private func approve(_ f: Fixture) async throws -> VoiceRevisionCandidate {
        let candidate = try await prepare(f)
        _ = try await f.repository.approveEditPlan(candidate.id,expectedSHA: try #require(candidate.editPlanSHA256))
        return try #require(try await f.repository.load().candidates.last)
    }
    @Test func repeatedExactApprovalIsIdempotentAcrossRepositories() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await prepare(f), other = try VoiceReviewRepository(project: f.project), sha = try #require(candidate.editPlanSHA256)
        async let first = f.repository.approveEditPlan(candidate.id,expectedSHA: sha)
        async let second = other.approveEditPlan(candidate.id,expectedSHA: sha)
        let (a,b) = try await (first,second)
        #expect(a.candidates.last?.editApproval?.id == b.candidates.last?.editApproval?.id)
        let path = f.project.folder.appendingPathComponent("notes/voice-review/edit-approvals")
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path).count == 1)
    }

    @MainActor @Test func oneApprovalCreatesVerifiedPreviewWithoutASeparateRenderAction() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pointer = f.project.folder.appendingPathComponent("cuts/current.json"), sentinel = Data("Keep the watched version".utf8)
        try sentinel.write(to: pointer)
        _ = try await note(f,action: .protect,start: 0,end: 12); _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await prepare(f), controller = try VoiceReviewController(project: f.project,provider: SyntheticVoiceReviewProvider())
        await controller.load()
        async let a: Void = controller.approveEditPlan(candidate,engine: f.engine)
        async let b: Void = controller.approveEditPlan(candidate,engine: f.engine)
        _ = await (a,b)
        let deadline = ContinuousClock.now + .seconds(20)
        while controller.renderingCandidateID != nil {
            guard ContinuousClock.now < deadline else { throw WorkflowFailure.invalid("Synthetic automatic preview did not finish") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let rendered = try #require(controller.document.candidates.last?.renderedPreview)
        #expect(rendered.frames == 24 && !rendered.appliedToWatchedVersion && !rendered.productionAuthorized)
        #expect(try await f.repository.verifiedPreview(candidate.id).lastPathComponent == "review.mov")
        #expect(try Data(contentsOf: pointer) == sentinel)
        #expect(controller.approvingCandidateIDs.isEmpty && controller.error == nil)
        await controller.approveEditPlan(candidate,engine: f.engine) // Delayed retry must reuse the completed preview.
        #expect(controller.renderingCandidateID == nil)
        let approvals = f.project.folder.appendingPathComponent("notes/voice-review/edit-approvals")
        #expect(try FileManager.default.contentsOfDirectory(atPath: approvals.path).count == 1)
        let outputs = f.project.folder.appendingPathComponent("build/voice-candidates")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputs.path).filter { UUID(uuidString: $0) != nil }.count == 1)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func quitWaitsForPendingApprovalAndDoesNotStartALatePreview() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await prepare(f), controller = try VoiceReviewController(project: f.project,provider: SyntheticVoiceReviewProvider())
        await controller.load()
        let fd = open(f.project.folder.appendingPathComponent("notes/voice-review/ledger.lock").path,O_RDWR)
        guard fd >= 0, flock(fd,LOCK_EX) == 0 else { throw WorkflowFailure.invalid("Synthetic approval lock unavailable") }
        defer { _ = flock(fd,LOCK_UN); close(fd) }
        let approval = Task { await controller.approveEditPlan(candidate,engine: f.engine) }
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.approvingCandidateIDs.isEmpty {
            guard ContinuousClock.now < deadline else { throw WorkflowFailure.invalid("Synthetic approval did not reserve its task") }
            await Task.yield()
        }
        #expect(controller.hasPendingWork)
        let exit = Task { await controller.flushForExit() }
        try await Task.sleep(for: .milliseconds(30))
        _ = flock(fd,LOCK_UN)
        await approval.value; #expect(await exit.value)
        #expect(controller.document.candidates.last?.editApproval != nil)
        #expect(controller.document.candidates.last?.renderedPreview == nil && controller.renderingCandidateID == nil)
        #expect(controller.approvingCandidateIDs.isEmpty && !controller.hasPendingWork)
        #expect(!FileManager.default.fileExists(atPath: f.project.folder.appendingPathComponent("build/voice-candidates").path))
    }

    @MainActor @Test func manualRetryCannotStealTheSlotFromAnApprovalWaitingForStorage() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let base = "cuts/v002/"
        try FileManager.default.copyItem(at: f.project.folder.appendingPathComponent("cuts/v001"),to: f.project.folder.appendingPathComponent("cuts/v002"))
        func inspect(_ path: String) throws -> VoiceArtifact { try VoiceReviewProvenance.inspect(base+path,project: f.project) }
        let bTarget = try VoiceReviewTarget(id: UUID(),projectID: f.project.id,versionID: UUID(),versionNumber: 2,versionMetadataSHA256: inspect("clauto-version.json").sha256,
            timeline: inspect("exports/cut.fcpxml"),preview: inspect("exports/review.mp4"),approvedPlanSHA256: inspect("plan/cut.plan.json").sha256,approvedPlanPath: base+"plan/cut.plan.json",
            approvedScriptSHA256: inspect("inputs/script/approved.md").sha256,approvedScriptPath: base+"inputs/script/approved.md",approvedBriefSHA256: inspect("inputs/brief.md").sha256,engineVersion: "synthetic",duration: f.target.duration)
        _ = try await f.repository.register(bTarget)
        _ = try await f.repository.addTyped(text: "Remove B range",action: .remove,anchor: .init(targetID: bTarget.id,seconds: 12*1001/24000.0,endSeconds: 24*1001/24000.0))
        let b = try await approve(f)
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let a = try await prepare(f), controller = try VoiceReviewController(project: f.project,provider: SyntheticVoiceReviewProvider())
        #expect(a.parent.id == f.target.id && b.parent.id == bTarget.id)
        await controller.load()
        let fd = open(f.project.folder.appendingPathComponent("notes/voice-review/ledger.lock").path,O_RDWR)
        guard fd >= 0, flock(fd,LOCK_EX) == 0 else { throw WorkflowFailure.invalid("Synthetic render slot lock unavailable") }
        defer { _ = flock(fd,LOCK_UN); close(fd) }
        let pending = Task { await controller.approveEditPlan(a,engine: f.engine) }
        let admissionDeadline = ContinuousClock.now + .seconds(3)
        while !controller.approvingCandidateIDs.contains(a.id) {
            guard ContinuousClock.now < admissionDeadline else { throw WorkflowFailure.invalid("Synthetic approval did not reserve slot") }; await Task.yield()
        }
        controller.renderPreview(b,engine: f.engine)
        #expect(controller.renderingCandidateID == nil)
        _ = flock(fd,LOCK_UN); await pending.value
        let renderDeadline = ContinuousClock.now + .seconds(20)
        while controller.renderingCandidateID != nil {
            guard ContinuousClock.now < renderDeadline else { throw WorkflowFailure.invalid("Synthetic reserved preview did not finish") }; try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.document.candidates.first(where: { $0.id == a.id })?.renderedPreview != nil)
        #expect(controller.document.candidates.first(where: { $0.id == b.id })?.renderedPreview == nil)
        #expect(controller.error == nil && controller.approvingCandidateIDs.isEmpty)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func cancellingAnActiveWorkerResultDoesNotShowAFailureBanner() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await prepare(f), runner = CancellablePreviewRunner()
        let controller = try VoiceReviewController(project: f.project,provider: SyntheticVoiceReviewProvider(),previewRunner: runner)
        await controller.load(); await controller.approveEditPlan(candidate,engine: f.engine)
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await runner.started) || controller.renderProgress != "Rendering approved movie ranges" {
            guard ContinuousClock.now < deadline else { throw WorkflowFailure.invalid("Synthetic worker did not start") }; try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.renderingCandidateID == candidate.id)
        await controller.cancelRender()
        #expect(controller.error == nil && controller.renderingCandidateID == nil)
        #expect(controller.document.candidates.last?.editApproval != nil && controller.document.candidates.last?.renderedPreview == nil)
        #expect(await controller.flushForExit())
    }

    @Test func structuredRemoveProtectAndHalfOpenBoundariesProduceExactParentFrameFragments() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await note(f,action: .protect,start: 0,end: 12)
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await prepare(f), plan = try #require(candidate.editPlan)
        #expect(plan.issues.isEmpty)
        #expect(plan.fragments.map(\.parentStartFrame) == [0,24])
        #expect(plan.fragments.map(\.parentEndFrame) == [12,36])
        #expect(plan.fragments.map(\.candidateStartFrame) == [0,12])
        #expect(candidate.editApproval == nil)
        await #expect(throws: (any Error).self) { _ = try await f.repository.approvedEditSnapshot(candidate.id) }
    }
    @Test func conflictAndUnsupportedOrPointOnlySpeechNeverAuthorizeRemoval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await note(f,action: .protect,start: 8,end: 18)
        _ = try await note(f,action: .remove,start: 12,end: 24)
        #expect(try await f.repository.load().notes.allSatisfy { $0.state == .needsResolution })
        #expect(try await f.repository.claim() == nil)
    }
    @Test func realReviewedH264AACMasterCandidateRendersExactFramesAndLeavesParentBytesAndCurrentUnchanged() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cut = f.project.folder.appendingPathComponent("cuts/current.json"), before = Data("Unchanged watched-version sentinel".utf8); try before.write(to: cut)
        let masterSHA = try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256
        _ = try await note(f,action: .protect,start: 0,end: 12)
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await approve(f)
        let result = try await VoiceCandidatePreviewService().render(repository: f.repository,candidateID: candidate.id,engine: f.engine)
        let record = try #require(result.candidates.last?.renderedPreview)
        #expect(record.frames == 24 && record.audioSamplesPerChannel == 48048)
        #expect(!record.productionAuthorized && !record.appliedToWatchedVersion)
        #expect(try await f.repository.verifiedPreview(candidate.id).lastPathComponent == "review.mov")
        #expect(try Data(contentsOf: cut) == before)
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == masterSHA)
        #expect(try Data(contentsOf: f.project.folder.appendingPathComponent(record.relativeFolder+"/parent.fcpxml")) == Data(contentsOf: f.project.folder.appendingPathComponent(f.target.timeline.relativePath)))
    }
    @Test func approvalIsInvalidatedByNewFeedbackAndChangedPlanBytes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await approve(f)
        _ = try await note(f,action: .protect,start: 24,end: 36)
        await #expect(throws: (any Error).self) { _ = try await f.repository.approvedEditSnapshot(candidate.id) }
        let next = try await approve(f)
        let path = try #require(next.editPlanRelativePath)
        try Data("Changed frame plan".utf8).write(to: f.project.folder.appendingPathComponent(path))
        await #expect(throws: (any Error).self) { _ = try await f.repository.approvedEditSnapshot(next.id) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_VOICE_CANDIDATE_ACCEPTANCE_ROOT"] != nil))
    func durableNASMasterCandidateUsesStrictLocalSnapshotAndKeepsOutputsOnNAS() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUTO_VOICE_CANDIDATE_ACCEPTANCE_ROOT"]!)
        let f = try await fixture(root: root)
        _ = try await note(f,action: .protect,start: 0,end: 12)
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await approve(f)
        let result = try await VoiceCandidatePreviewService().render(repository: f.repository,candidateID: candidate.id,engine: f.engine)
        let record = try #require(result.candidates.last?.renderedPreview)
        let evidence = try JSONEncoder().encode(record)
        try evidence.write(to: f.project.folder.appendingPathComponent("VOICE_CANDIDATE_NAS_ACCEPTANCE.json"),options: .withoutOverwriting)
        print("VOICE_CANDIDATE_NAS_ACCEPTANCE_PROJECT="+f.project.folder.path)
        #expect(record.frames == 24)
        #expect(try await f.repository.verifiedPreview(candidate.id).path.hasPrefix(root.path))
    }
    @Test func verifiedMovieImportCopiesOnlySelectedArtifactsIntoANewReviewOnlyProject() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let movie = f.project.folder.appendingPathComponent(f.target.preview.relativePath)
        let receipt = f.project.folder.appendingPathComponent("synthetic-verification.json")
        try JSONSerialization.data(withJSONObject: ["sha256":f.target.preview.sha256,"review":movie.path,"technical_checks_passed":true,"duration_seconds":f.target.duration,"actual_frames":36]).write(to: receipt)
        let lineage = f.project.folder.appendingPathComponent("compound-lineage.fcpxml")
        let lineageData = try Data(contentsOf: f.project.folder.appendingPathComponent(f.target.timeline.relativePath))
        let compound = String(decoding: lineageData,as: UTF8.self).replacingOccurrences(of: "<resources/>",with: "<resources><media id=\"compound\"><sequence duration=\"1s\"><spine/></sequence></media></resources>")
        try Data(compound.utf8).write(to: lineage)
        let imported = try await ReviewMovieImportService().importReview(.init(movie: movie,movieSHA256: f.target.preview.sha256,nativeTimeline: lineage,script: f.project.folder.appendingPathComponent(f.target.approvedScriptPath),plan: f.project.folder.appendingPathComponent(f.target.approvedPlanPath),brief: f.project.folder.appendingPathComponent("cuts/v001/inputs/brief.md"),verificationReceipt: receipt,number: 7,label: "Generated reviewed movie v7"),root: f.root.appendingPathComponent("imported"),engine: f.engine)
        #expect(imported.manifest.importedReviewOnly == true && imported.folder != f.project.folder)
        let workflow = WorkflowRepository(), version = try #require(try await workflow.current(project: imported))
        #expect(version.number == 7)
        let target = try await workflow.voiceReviewTarget(version,project: imported)
        #expect(target.preview.sha256 == f.target.preview.sha256)
        #expect(target.timeline.sha256 == TranscriptSourceMap.sha(Data(compound.utf8)))
        #expect(abs(target.duration-f.target.duration) < 0.00001)
        await #expect(throws: (any Error).self) { _ = try await workflow.prepare(project: imported,engine: f.engine,label: "No new production cut") }
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == f.target.preview.sha256)
    }

    @Test func changedFeedbackDuringRenderCannotCommitOrReplaceWatchedVersion() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await note(f,action: .remove,start: 12,end: 24)
        let candidate = try await approve(f)
        await #expect(throws: (any Error).self) {
            _ = try await VoiceCandidatePreviewService().render(repository: f.repository,candidateID: candidate.id,engine: f.engine,onCheckpoint: { phase,_ in
                if case .workerFinished = phase { _ = try await f.repository.addTyped(text: "Protect the final passage",action: .protect,anchor: .init(targetID: f.target.id,seconds: 24*1001/24000,endSeconds: 36*1001/24000)) }
            })
        }
        #expect(try await f.repository.load().candidates.first?.renderedPreview == nil)
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == f.target.preview.sha256)
    }
    @Test func rehashedWrongTimelineLineageApprovalAndSizesCannotPublish() async throws {
        for mode in ["format","formatAndProof","movieAndProof","nested","plan","approval","lineage","sizes","input"] {
            let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try await note(f,action: .remove,start: 12,end: 24)
            let candidate = try await approve(f)
            await #expect(throws: (any Error).self) {
                _ = try await VoiceCandidatePreviewService().render(repository: f.repository,candidateID: candidate.id,engine: f.engine,onCheckpoint: { phase,stage in
                    guard case .workerFinished = phase else { return }
                    let proofPath = stage.appendingPathComponent("render-proof.json")
                    var proof = try JSONSerialization.jsonObject(with: Data(contentsOf: proofPath)) as! [String:Any]
                    let file: String
                    switch mode {
                    case "format", "formatAndProof":
                        if mode == "formatAndProof" { proof["width"] = 1920 }
                        file = "timeline.fcpxml"; let path=stage.appendingPathComponent(file); let text=try String(contentsOf: path,encoding: .utf8).replacingOccurrences(of: "width=\"160\"",with: "width=\"1920\""); try Data(text.utf8).write(to: path)
                    case "movieAndProof":
                        file = "review.mov"
                        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),arguments: ["-v","error","-nostdin","-f","lavfi","-i","color=c=yellow:s=160x90:r=24000/1001","-f","lavfi","-i","sine=frequency=800:sample_rate=48000","-frames:v","24","-af","atrim=end_sample=48048","-c:v","libx264","-pix_fmt","yuv420p","-c:a","pcm_s16le","-y",stage.appendingPathComponent(file).path],timeout: .seconds(30)),onLine: nil)
                        guard result.succeeded else { throw WorkflowFailure.invalid(result.error) }
                    case "nested": file = "timeline.fcpxml"; let path=stage.appendingPathComponent(file); let text=try String(contentsOf: path,encoding: .utf8).replacingOccurrences(of: "</resources>",with: "<effect id=\"extra\" name=\"Unapproved\" uid=\"unknown\"/></resources>"); try Data(text.utf8).write(to: path)
                    case "plan": file = "candidate-plan.json"; try Data("{}".utf8).write(to: stage.appendingPathComponent(file))
                    case "approval": file = "candidate-approval.json"; try Data("{}".utf8).write(to: stage.appendingPathComponent(file))
                    case "lineage": file = "source-map.json"; try Data("{}".utf8).write(to: stage.appendingPathComponent(file))
                    case "input": file = "input.json"; try Data("{}".utf8).write(to: stage.appendingPathComponent(file))
                    default: file = ""; proof["artifactSizes"] = [:]
                    }
                    if !file.isEmpty && file != "input.json" {
                        let bytes = try Data(contentsOf: stage.appendingPathComponent(file))
                        var hashes=proof["artifactsSHA256"] as! [String:String];hashes[file]=TranscriptSourceMap.sha(bytes);proof["artifactsSHA256"]=hashes
                        var sizes=proof["artifactSizes"] as! [String:Int];sizes[file]=bytes.count;proof["artifactSizes"]=sizes
                    }
                    try JSONSerialization.data(withJSONObject: proof,options: [.sortedKeys]).write(to: proofPath)
                })
            }
            #expect(try await f.repository.load().candidates.last?.renderedPreview == nil)
        }
    }

}
