import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
import AppKit
import SwiftUI
#endif

private func experienceRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-experience-"+UUID().uuidString)
    try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
    return root.resolvingSymlinksInPath().standardizedFileURL
}
struct ProjectExperienceTests {
    @Test func chatIsAPersistedProjectWorkspace() {
        #expect(RecentProjectRestoration.tab("Chat") == "Chat")
        #expect(RecentProjectRestoration.tab("Files") == "Files")
        #expect(RecentProjectRestoration.tab("unknown") == "Brief")
    }
    @Test func groupsKeepNativeIdentitiesAndOfflineVersionsWithoutNameHeuristics() async throws {
        let root = try experienceRoot();defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(),a = try await repository.create(name: "Pizza v7",root: root,engine: root),b = try await repository.create(name: "Pizza cadence",root: root,engine: root),other = try await repository.create(name: "Pan",root: root,engine: root)
        let group = ProjectLibraryGroup(id: UUID(),name: "Pizza yeast",members: [a.id,b.id])
        try ProjectLibraryGroup.validate([group])
        let rows = ProjectLibraryEntry.entries(projects: [a,other],bookmarks: [a,b,other].map(ProjectCatalogBookmark.init),groups: [group])
        #expect(rows.count == 2 && rows[0].name == "Pizza yeast" && rows[0].memberIDs == [a.id,b.id])
        #expect(rows[1].id == other.id)
        #expect(ProjectLibraryEntry.entries(projects: [a,b,other],bookmarks: [],groups: []).count == 3)
        let duplicate = ProjectLibraryGroup(id: UUID(),name: "Other",members: [a.id,other.id])
        #expect(throws: (any Error).self) { try ProjectLibraryGroup.validate([group,duplicate]) }
        let reopenedA = try await repository.open(a.folder),reopenedB = try await repository.open(b.folder)
        #expect(reopenedA.id == a.id && reopenedB.id == b.id)
    }
    @Test func everyStarterIsValidEditableAndUsesTheProjectShape() throws {
        for starter in StudioStarter.allCases {
            var scene = starter.scene(projectName: "Pizza yeast",aspect: "9:16")
            try scene.validate()
            #expect(scene.width == 720 && scene.height == 1280)
            if scene.kind == .titleCard {
                #expect(!scene.textLayers.isEmpty)
                scene.textLayers[0].text = "My new words";try scene.validate()
                let bytes = try JSONEncoder().encode(scene)
                #expect(try JSONDecoder().decode(GraphicScene.self,from: bytes).textLayers[0].text == "My new words")
            }
        }
    }
    @MainActor @Test func starterCreationEditsAndReopensAsARealProjectScene() async throws {
        let root = try experienceRoot();defer { try? FileManager.default.removeItem(at: root) }
        let project = try await ProjectRepository().create(name: "Template project",root: root,engine: root)
        let controller = GraphicStudioController(project: project)
        controller.create(template: .lowerThird)
        for _ in 0..<500 { if controller.busy == nil { break };try await Task.sleep(for: .milliseconds(10)) }
        #expect(await controller.flushForExit())
        let draft = try #require(controller.draft)
        #expect(draft.scene.kind == .titleCard && draft.scene.textLayers.count == 2)
        controller.changeScene(draft.id) { $0.scene.textLayers[0].text = "Katie" }
        #expect(await controller.flushForExit())
        let reopened = try await GraphicStudioRepository().load(project,id: draft.id)
        #expect(reopened.draft.scene.textLayers[0].text == "Katie")
        #expect(reopened.draft.scene.textLayers[1].text == "Add a short explanation")
    }
    @Test func titleTemplateRendersActualTransparentTextWithoutScientificFooter() async throws {
        var scene = StudioStarter.title.scene(projectName: "My film",aspect: "16:9");scene.width = 640;scene.height = 360
        let image = try await GraphicSceneRenderer().render(scene,frame: 0)
        let alphas = stride(from: 3,to: image.rgba.count,by: 4).map { image.rgba[$0] }
        #expect(alphas.contains { $0 > 0 } && alphas.contains(0))
        let footer = (Int(Double(image.height)*0.94)*image.width+image.width/2)*4+3
        #expect(image.rgba[footer] == 0)
    }
    @Test func illustratedCoversAreImmutableBoundedAndHashChecked() async throws {
        let root = try experienceRoot();defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"),raster = CutoutRaster(width: 32,height: 32,rgba: Data(repeating: 255,count: 32*32*4))
        let bytes = try CutoutImageIO.png(raster);try bytes.write(to: source)
        let repository = ProjectCoverRepository(root: root.appendingPathComponent("covers")),id = UUID()
        let record = try await repository.save(source,projectID: id,generator: "Synthetic test only",prompt: "Test prompt",expectedSHA256: TranscriptSourceMap.sha(bytes))
        #expect(record.projectID == id && record.sourceSHA256 == TranscriptSourceMap.sha(bytes))
        #expect(try CutoutImageIO.decode(await repository.thumbnail(record)).raster.width <= 512)
        #expect(try Data(contentsOf: source) == bytes)
        await #expect(throws: (any Error).self) { _ = try await repository.save(source,projectID: id,generator: "Test",prompt: "",expectedSHA256: String(repeating: "a",count: 64)) }
        var traversal = record;traversal.filename = "../source.png"
        await #expect(throws: (any Error).self) { _ = try await repository.thumbnail(traversal) }
        let saved = root.appendingPathComponent("covers/"+id.uuidString+"/"+record.filename)
        try Data("changed".utf8).write(to: saved)
        await #expect(throws: (any Error).self) { _ = try await repository.thumbnail(record) }
    }
    @Test func verifiedMovieCanAppendToAnExistingProjectWithoutReplacingItsCurrentCut() async throws {
        let f = try await FrameReviewFixture.make();defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("synthetic".utf8).write(to: f.root.appendingPathComponent("ENGINE_VERSION"))
        let original = CutVersion(number: 1,label: "Original",engineVersion: "synthetic",runID: UUID(),artifacts: ["exports/review.mp4"],approvedPlanHash: "fixture")
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let metadata = f.project.folder.appendingPathComponent("cuts/v001/clauto-version.json"),pointer = f.project.folder.appendingPathComponent("cuts/current.json")
        try encoder.encode(original).write(to: metadata);try encoder.encode(original.id).write(to: pointer)
        let pointerBefore = try Data(contentsOf: pointer),metadataBefore = try Data(contentsOf: metadata)
        let receipt = f.root.appendingPathComponent("receipt.json"),movie = f.root.appendingPathComponent("verified.mp4")
        let resultMovie = try await ProcessRunner().run(.init(executable: ProcessRunner.executable("ffmpeg")!,arguments: ["-nostdin","-v","error","-f","lavfi","-i","color=s=160x90:r=24000/1001","-frames:v","36","-c:v","libx264","-bf","0","-video_track_timescale","24000","-pix_fmt","yuv420p",movie.path]))
        #expect(resultMovie.succeeded)
        let movieSHA = TranscriptSourceMap.sha(try Data(contentsOf: movie))
        try JSONSerialization.data(withJSONObject: ["sha256":movieSHA,"review":movie.path,"technical_checks_passed":true,"duration_seconds":f.target.duration,"actual_frames":36]).write(to: receipt)
        let request = ReviewMovieImportRequest(movie: movie,movieSHA256: movieSHA,nativeTimeline: nil,script: f.project.folder.appendingPathComponent(f.target.approvedScriptPath),plan: f.project.folder.appendingPathComponent(f.target.approvedPlanPath),brief: f.project.folder.appendingPathComponent("cuts/v001/inputs/brief.md"),verificationReceipt: receipt,number: 1,label: "Another verified edition")
        let result = try await ReviewMovieImportService().importReview(request,root: f.root,engine: f.root,existingProject: f.project)
        #expect(result.id == f.project.id && result.folder == f.project.folder)
        #expect(try Data(contentsOf: pointer) == pointerBefore && Data(contentsOf: metadata) == metadataBefore)
        #expect(try await WorkflowRepository().versions(project: result).map(\.number).sorted() == [1,2])
        let binding = try Data(contentsOf: result.folder.appendingPathComponent("cuts/v002/inputs/import-binding.json"))
        let object = try #require(JSONSerialization.jsonObject(with: binding) as? [String:Any])
        #expect(object["originalVersionNumber"] as? Int == 1 && object["number"] as? Int == 2)
        #expect(object["productionAuthorized"] as? Bool == false)
        #expect(object["timelineKind"] as? String == "single_rendered_movie_reference" && object["originalSourceLayersEditable"] as? Bool == false)
        let xml = try XMLDocument(contentsOf: result.folder.appendingPathComponent("cuts/v002/exports/watched.fcpxml"),options: .nodeLoadExternalEntitiesNever)
        #expect(try xml.nodes(forXPath: "/fcpxml/resources/asset").count == 1)
        let src = try #require(xml.nodes(forXPath: "/fcpxml/resources/asset/media-rep/@src").first?.stringValue)
        #expect(URL(string: src) == result.folder.appendingPathComponent("cuts/v002/exports/verified.mp4"))
        _ = try await ReviewMovieImportService().importReview(request,root: f.root,engine: f.root,existingProject: result)
        #expect(try await WorkflowRepository().versions(project: result).count == 2)
        #expect(try Data(contentsOf: pointer) == pointerBefore)
        let importedVersion = try #require(try await WorkflowRepository().versions(project: result).first { $0.number == 2 })
        let target = try await WorkflowRepository().voiceReviewTarget(importedVersion,project: result)
        #expect(target.preview.sha256 == movieSHA && target.versionNumber == 2)
    }
}

#if !canImport(ClautoCore)
@MainActor @Suite(.serialized) struct ProjectExperienceNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_DEFAULTS_SUITE"] != nil && ProcessInfo.processInfo.environment["CLAUTO_COVERS_ROOT"] != nil, "Requires the explicit private-profile test host"))
    func privateProfileUsesOnlyItsRequestedPreferencesAndRoots() throws {
        let env = ProcessInfo.processInfo.environment
        let suite = try #require(env["CLAUTO_DEFAULTS_SUITE"])
        #expect(suite.hasPrefix("ClautoVideo.NativeRegression."))
        let preferences = try #require(UserDefaults(suiteName: suite))
        let otherSuite = UUID().uuidString,other = try #require(UserDefaults(suiteName: otherSuite))
        defer { other.removePersistentDomain(forName: otherSuite) }
        let key = "ClautoSelectedProjectTab",original = UserDefaults.standard.string(forKey: key),previous = preferences.string(forKey: key)
        defer { if let previous { preferences.set(previous,forKey: key) } else { preferences.removeObject(forKey: key) } }
        let store = EditorStore(defaults: other)
        store.rememberProjectTab("Studio")
        #expect(preferences.string(forKey: key) == "Studio" && other.string(forKey: key) == nil)
        #expect(UserDefaults.standard.string(forKey: key) == original)
        #expect(store.projectRoot.path == env["CLAUTO_PROJECTS_ROOT"] && store.engineRoot.path == env["CLAUTO_ENGINE_ROOT"])
        let covers = try #require(env["CLAUTO_COVERS_ROOT"])
        #expect(ProjectCoverRepository().root.path == covers)
        let explicit = URL(fileURLWithPath: covers).appendingPathComponent("explicit-test-root")
        #expect(ProjectCoverRepository(root: explicit).root == explicit)
    }
    @Test func renamedAppPreservesItsExistingBundleAndExecutableIdentity() {
        #expect(Bundle.main.bundleIdentifier == "com.nathanfennel.Clauto-Editor")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Clauto Video")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Clauto Video")
        #expect(Bundle.main.executableURL?.lastPathComponent == "Clauto Editor")
        #expect(Bundle.main.bundleURL.lastPathComponent == "Clauto Video.app")
    }
    @Test func groupingPersistsAndSwitchesVersionsWithoutChangingProjectBytesOrDrafts() async throws {
        let root = try experienceRoot();defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ProjectRepository(),a = try await repository.create(name: "Pizza v7",root: root,engine: root),b = try await repository.create(name: "Pizza cadence",root: root,engine: root),other = try await repository.create(name: "Pan",root: root,engine: root)
        let before = try [a,b,other].map { try Data(contentsOf: $0.folder.appendingPathComponent("clauto-project.json")) }
        defaults.set(root.path,forKey: "ClautoProjectsRoot")
        let store = EditorStore(defaults: defaults);await store.restore();store.selectedID = b.id
        let chat = store.liveConversation(for: b)
        store.groupProjects([a.id,b.id],name: "Pizza yeast");store.selectedID = b.id;store.rememberProjectTab("Chat")
        let group = try #require(store.libraryEntries.first { $0.groupID != nil })
        store.selectedID = other.id;await store.selectLibraryEntry(group)
        #expect(store.selectedID == b.id && store.initialProjectTab == "Chat" && store.liveConversation(for: b) === chat)
        #expect(store.libraryEntries.count == 2 && store.projects.count == 3)
        let reopened = EditorStore(defaults: defaults);await reopened.restore()
        #expect(reopened.libraryEntries.count == 2 && reopened.libraryGroup(for: a.id)?.name == "Pizza yeast")
        #expect(try [a,b,other].map { try Data(contentsOf: $0.folder.appendingPathComponent("clauto-project.json")) } == before)
        store.ungroupProject(b.id);#expect(store.libraryEntries.count == 3)
        #expect(await store.flushReviewWorkForExit())
    }
    @Test func authoredCloseWorksWithHiddenNativeControlAndHonorsDelegateVeto() {
        final class Gate: NSObject,NSWindowDelegate {
            var permit = false
            var calls = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { calls += 1;return permit }
        }
        let window = NSWindow(contentRect: .init(x: -2000,y: -2000,width: 320,height: 240),styleMask: [.titled,.closable],backing: .buffered,defer: false),gate = Gate()
        window.isReleasedWhenClosed = false;window.delegate = gate;window.setIsVisible(true)
        let button = window.standardWindowButton(.closeButton);button?.isHidden = true
        ClautoWindowActions.close(window)
        #expect(gate.calls == 1 && window.isVisible && button?.isHidden == true)
        gate.permit = true;ClautoWindowActions.close(window)
        #expect(gate.calls == 2 && !window.isVisible)
        window.close()
    }
}
#endif

#if !canImport(ClautoCore)
extension ProjectExperienceNativeTests {
    @Test func retryMissingPreviewRequiresSavedBytesAndKeepsSessionAndDraftOwnership() async throws {
        let f = try await FrameReviewFixture.make();defer { try? FileManager.default.removeItem(at: f.root) }
        let base = f.project.folder.appendingPathComponent("cuts/v001"),movie = base.appendingPathComponent("exports/review.mp4")
        let movieBytes = try Data(contentsOf: movie),movieSHA = TranscriptSourceMap.sha(movieBytes)
        let xml = Data(ReviewMovieImportService.flatReviewXML(movie: movie,frames: 36,width: 160,height: 90).utf8)
        try xml.write(to: base.appendingPathComponent("exports/cut.fcpxml"))
        try JSONSerialization.data(withJSONObject: ["saved_sha256":TranscriptSourceMap.sha(xml)]).write(to: base.appendingPathComponent("exports/cut.snapshot.json"))
        let receipt = try JSONSerialization.data(withJSONObject: ["sha256":movieSHA,"technical_checks_passed":true])
        try receipt.write(to: base.appendingPathComponent("inputs/original-verification.json"))
        var version = CutVersion(number: 1,label: "Synthetic reconnect review",engineVersion: "synthetic",runID: UUID(),artifacts: ["exports/review.mp4","exports/cut.fcpxml","exports/cut.snapshot.json","plan/cut.plan.json","inputs/import-binding.json"],approvedPlanHash: f.target.approvedPlanSHA256,briefHash: f.target.approvedBriefSHA256,approvedScript: "inputs/script/approved.md")
        version.id = f.target.versionID
        let binding: [String:Any] = ["scope":"review_existing_movie_only","projectID":f.project.id.uuidString,"versionID":version.id.uuidString,"movieSHA256":movieSHA,"verificationReceiptSHA256":TranscriptSourceMap.sha(receipt)]
        try JSONSerialization.data(withJSONObject: binding).write(to: base.appendingPathComponent("inputs/import-binding.json"))
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(version).write(to: base.appendingPathComponent("clauto-version.json"))
        try encoder.encode(version.id).write(to: f.project.folder.appendingPathComponent("cuts/current.json"))
        let target = try await WorkflowRepository().voiceReviewTarget(version,project: f.project)
        let request = FrameCommentRequest(id: UUID(),target: target,frame: try .capture(.init(value: 0,timescale: 24000),duration: target.duration))
        let frozen = try await ReviewFrameCaptureService().capture(request,project: f.project)
        let savedFrame = try await FrameCommentRepository(project: f.project).save(frame: frozen,text: "Saved frame feedback",annotations: [])
        let voiceRepository = try VoiceReviewRepository(project: f.project)
        let registered = try await voiceRepository.register(target)
        let savedVoice = try await voiceRepository.addTyped(text: "Saved voice history",action: .protect,anchor: .init(targetID: registered.id,seconds: 0,endSeconds: 0.5))
        let savedNoteID = try #require(savedVoice.notes.first?.id)
        var savedDraft = VoiceTypedDraft(versionID: version.id)
        savedDraft.text = "Keep this unfinished feedback";savedDraft.start = "0.25";savedDraft.target = registered
        _ = try await voiceRepository.saveTypedDraft(savedDraft,expected: nil)
        // A malformed peer must not prevent this independently verified review.
        let bad = f.project.folder.appendingPathComponent("cuts/v002")
        try FileManager.default.createDirectory(at: bad,withIntermediateDirectories: false)
        try Data("bad peer metadata".utf8).write(to: bad.appendingPathComponent("clauto-version.json"))
        let held = f.root.appendingPathComponent("held-original.mp4");try FileManager.default.moveItem(at: movie,to: held)
        let suite = UUID().uuidString,defaults = try #require(UserDefaults(suiteName: suite));defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorStore(defaults: defaults),router = ReviewWindowRouter();router.store = store;router.intendedVersionID = version.id
        let provider = MockVoiceProvider(),voice = try VoiceReviewController(project: f.project,provider: provider,defaults: defaults)
        store.voiceReviews[f.project.id] = voice
        let composer = voice.typedComposer(for: version.id)
        let chat = store.liveConversation(for: f.project);await chat.load();chat.edit("Keep this unsent project draft")
        let session = store.reviewPlayer(project: f.project,version: version,url: movie,ownerID: router.id),player = session.player
        defer { session.dispose();store.reviewPlayers.removeValue(forKey: session.id) }
        session.attach(to: router)
        for _ in 0..<500 { if session.canRetryPreview { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(session.issue != nil && !session.ready)
        #expect(store.frameComments[f.project.id] == nil && voice.document.notes.isEmpty && composer.text.isEmpty)
        try FileManager.default.moveItem(at: held,to: movie)
        session.retryPreview();session.retryPreview() // the in-flight retry owns one session
        for _ in 0..<1000 { if session.ready && !session.checkingPreview { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(session.ready && session.issue == nil && session.endpoint?.target.preview.sha256 == movieSHA)
        let comments = try #require(store.frameComments[f.project.id])
        #expect(comments.comments.contains { $0.id == savedFrame.id && $0.text == "Saved frame feedback" })
        #expect(session.voice === voice && voice.document.notes.contains { $0.id == savedNoteID && $0.text == "Saved voice history" })
        #expect(voice.typedComposer(for: version.id) === composer && composer.text == savedDraft.text && composer.start == savedDraft.start)
        #expect(!voice.isAttached(to: session.id) && voice.target == nil && !voice.active && !session.bindingVoice)
        #expect(await provider.starts == 0)
        #expect(await provider.microphoneRequests == 0)
        #expect(await provider.speechRequests == 0)
        #expect(session.player === player && store.reviewPlayers.count == 1 && !session.playing)
        #expect(store.reviewPlayer(project: f.project,version: version,url: movie,ownerID: router.id) === session)
        #expect(chat.draft.text == "Keep this unsent project draft")
        session.selectForVoice() // Only this explicit action may bind the recovered movie.
        for _ in 0..<1000 { if voice.isAttached(to: session.id) && !session.bindingVoice { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(voice.isAttached(to: session.id) && voice.target?.preview.sha256 == movieSHA && !voice.active)
        #expect(await provider.starts == 0)
        #expect(await provider.microphoneRequests == 0)
        #expect(await provider.speechRequests == 0)
        session.leaveWorkspace();session.attach(to: router) // Revisit takes the cached-endpoint path.
        #expect(store.frameComments[f.project.id] === comments && session.voice === voice && !voice.isAttached(to: session.id))
        #expect(comments.comments.contains { $0.id == savedFrame.id } && voice.document.notes.contains { $0.id == savedNoteID })
        #expect(composer.text == savedDraft.text && chat.draft.text == "Keep this unsent project draft")
        try Data("different bytes at the same path".utf8).write(to: movie)
        session.issue = "Synthetic disconnected preview"
        for _ in 0..<1000 { if session.canRetryPreview { break };try await Task.sleep(for: .milliseconds(2)) }
        session.retryPreview()
        for _ in 0..<1000 { if session.canRetryPreview { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(!session.ready && session.issue != nil && session.endpoint == nil && session.player.currentItem == nil)
        #expect(chat.draft.text == "Keep this unsent project draft" && store.reviewPlayers.count == 1)
        #expect(await store.flushReviewWorkForExit())
    }
}
#endif
