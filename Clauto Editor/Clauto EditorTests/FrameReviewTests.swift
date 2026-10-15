import Foundation
import Testing
import AVFoundation
import ImageIO
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct FrameReviewFixture {
    let root: URL
    let project: Project
    let target: VoiceReviewTarget
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-frame-qa-"+UUID().uuidString)
        let project = try await ProjectRepository().create(name: "Synthetic frame review",root: root,engine: root,engineVersion: "synthetic")
        let base = project.folder.appendingPathComponent("cuts/v001")
        for path in ["exports","plan","inputs/script"] { try FileManager.default.createDirectory(at: base.appendingPathComponent(path),withIntermediateDirectories: true) }
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),arguments: ["-v","error","-nostdin","-n","-f","lavfi","-i","nullsrc=s=160x90:r=24000/1001,geq=lum='20+5*N':cb=128:cr=128","-frames:v","36","-c:v","libx264","-bf","2","-pix_fmt","yuv420p",base.appendingPathComponent("exports/review.mp4").path],timeout: .seconds(30)))
        guard result.succeeded else { throw WorkflowFailure.invalid(result.error) }
        for path in ["exports/cut.fcpxml","clauto-version.json","plan/cut.plan.json","inputs/script/approved.md","inputs/brief.md"] { try Data(("Synthetic "+path).utf8).write(to: base.appendingPathComponent(path)) }
        func artifact(_ path: String) throws -> VoiceArtifact { try VoiceReviewProvenance.inspect("cuts/v001/"+path,project: project) }
        let target = try VoiceReviewTarget(id: UUID(),projectID: project.id,versionID: UUID(),versionNumber: 1,versionMetadataSHA256: artifact("clauto-version.json").sha256,timeline: artifact("exports/cut.fcpxml"),preview: artifact("exports/review.mp4"),approvedPlanSHA256: artifact("plan/cut.plan.json").sha256,approvedPlanPath: "cuts/v001/plan/cut.plan.json",approvedScriptSHA256: artifact("inputs/script/approved.md").sha256,approvedScriptPath: "cuts/v001/inputs/script/approved.md",approvedBriefSHA256: artifact("inputs/brief.md").sha256,engineVersion: "synthetic",duration: Double(36*1001)/24000)
        return .init(root: root,project: project,target: target)
    }
    func request(frame: Int = 12) throws -> FrameCommentRequest {
        .init(id: UUID(),target: target,frame: try .capture(.init(value: Int64(frame)*1001,timescale: 24000),duration: target.duration))
    }
}

@MainActor final class FakeReviewDriver: ReviewPlaybackDriving {
    var ready = true
    var seeking = false
    var value = ReviewClockTime(value: 12500,timescale: 24000)
    var log: [String] = []
    var lastSeek: Double?
    var clock: ReviewClockTime? { log.append("clock"); return value }
    func pause() { log.append("pause") }
    func toggle() { log.append("toggle") }
    func seek(seconds: Double) { lastSeek = seconds; seeking = true }
}
private actor DelayedFrameCapture: ReviewFrameCapturing {
    let frozen: FrozenReviewFrame
    private var calls = 0
    init(_ frozen: FrozenReviewFrame) { self.frozen = frozen }
    func capture(_ request: FrameCommentRequest,project: Project) async throws -> FrozenReviewFrame {
        calls += 1
        // Deliberately ignore cancellation until completion, like a late decoder.
        try? await Task.sleep(for: .milliseconds(80))
        return .init(request: request,png: frozen.png,pngSHA256: frozen.pngSHA256,width: frozen.width,height: frozen.height,actualTime: .init(value: request.frame.presentationValue,timescale: 24000))
    }
    func cancel(_ id: UUID) {}
}

struct FrameReviewTests {
    @Test func containingFrameUsesRationalFloorAndMapsDurationToLastFrame() throws {
        let duration = Double(36*1001)/24000
        #expect(try ReviewFrameAnchor.capture(.init(value: 12011,timescale: 24000),duration: duration).frameIndex == 11)
        #expect(try ReviewFrameAnchor.capture(.init(value: 12012,timescale: 24000),duration: duration).frameIndex == 12)
        #expect(try ReviewFrameAnchor.capture(.init(value: 12013,timescale: 24000),duration: duration).frameIndex == 12)
        #expect(try ReviewFrameAnchor.capture(.init(value: 36*1001,timescale: 24000),duration: duration).frameIndex == 35)
        for clock in [ReviewClockTime(value: -1,timescale: 24000),.init(value: 1,timescale: 0),.init(value: .max,timescale: 1),.init(value: 40*1001,timescale: 24000)] { #expect(throws: (any Error).self) { try ReviewFrameAnchor.capture(clock,duration: duration) } }
        for value in [Double.nan,Double.infinity,0,1,Double(86401*1001)/24000] { #expect(throws: (any Error).self) { try ReviewFrameAnchor.capture(.init(value: 0,timescale: 1),duration: value) } }
    }
    @MainActor @Test func pauseFreezesBeforeClockReadAndSeekPendingRefuses() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let driver = FakeReviewDriver(), endpoint = ReviewPlaybackEndpoint(id: UUID(),project: f.project,target: f.target,driver: driver)
        let request = try endpoint.pauseAndFreeze()
        #expect(driver.log == ["pause","clock"])
        driver.value = .init(value: 0,timescale: 24000)
        #expect(request.target == f.target && request.frame.clock.value == 12500 && request.frame.frameIndex == 12)
        endpoint.skip(5); #expect(driver.lastSeek == f.target.duration)
        #expect(throws: (any Error).self) { try endpoint.pauseAndFreeze() }
        driver.seeking = false; endpoint.skip(-5); #expect(driver.lastSeek == 0)
    }
    @MainActor @Test func configurableSkipPersistsAndRejectsNonfiniteOutOfRangeValues() throws {
        let name = "clauto-frame-prefs-"+UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = ReviewPlaybackPreferences(defaults: defaults); #expect(prefs.skipSeconds == 5)
        try prefs.setSkip(2.5); #expect(ReviewPlaybackPreferences(defaults: defaults).skipSeconds == 2.5)
        for bad in [0,61,Double.nan,Double.infinity] { #expect(throws: (any Error).self) { try prefs.setSkip(bad) } }
        #expect(prefs.skipSeconds == 2.5)
    }
    @MainActor @Test func realAVPlayerSeeksAndReplaysWithoutForegroundOrAudio() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let player = AVPlayer(url: f.project.folder.appendingPathComponent(f.target.preview.relativePath)), control = ReviewPlaybackControl()
        player.isMuted = true; control.player = player
        defer { control.pause(); control.detach(player) }
        for _ in 0..<250 { if control.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(control.ready)
        let end = CMTime(seconds: f.target.duration,preferredTimescale: 24000)
        #expect(await player.seek(to: end,toleranceBefore: .zero,toleranceAfter: .zero))
        var requested = 0, completed = 0
        control.onSeekRequested = { requested += 1 }; control.onSeekCompleted = { if $0 { completed += 1 } }
        control.toggle()
        for _ in 0..<150 { if !control.seeking && player.timeControlStatus == .playing { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(requested == 1 && completed == 1 && player.timeControlStatus == .playing)
        #expect(player.currentTime().seconds < f.target.duration/2)
        control.pause(); control.seek(seconds: 0.75)
        for _ in 0..<150 { if !control.seeking { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(player.timeControlStatus == .paused && abs(player.currentTime().seconds-0.75)<1.0/24000)
        #expect(requested == 2 && completed == 2)
    }
    @Test func textAndModalFocusNeverPermitPlaybackShortcuts() {
        for text in [false,true] { for modal in [false,true] { for ready in [false,true] {
            #expect(ReviewShortcutPolicy.permits(textEditing: text,modalPresented: modal,selectedPlayerReady: ready) == (!text && !modal && ready))
        } } }
    }
    @Test func letterboxesResizeAndReverseDragKeepNormalizedVideoCoordinates() throws {
        let wide = try #require(VideoAnnotationGeometry.videoRect(image: CGSize(width: 1920,height: 1080),canvas: CGRect(x: 0,y: 0,width: 500,height: 500)))
        #expect(abs(wide.minX)<1e-9 && abs(wide.minY-109.375)<1e-9 && abs(wide.width-500)<1e-9 && abs(wide.height-281.25)<1e-9)
        #expect(VideoAnnotationGeometry.drawn(from: .init(x: 100,y: 20),to: .init(x: 200,y: 200),kind: .ellipse,video: wide) == nil)
        let rect = try #require(VideoAnnotationGeometry.drawn(from: .init(x: 400,y: 350),to: .init(x: 100,y: 200),kind: .ellipse,video: wide))
        #expect(abs(rect.x-0.2)<1e-9 && abs(rect.width-0.6)<1e-9)
        let twice = try #require(VideoAnnotationGeometry.videoRect(image: CGSize(width: 1920,height: 1080),canvas: CGRect(x: 0,y: 0,width: 1000,height: 1000)))
        #expect(VideoAnnotationGeometry.display(rect,video: twice).width == 2*VideoAnnotationGeometry.display(rect,video: wide).width)
        let tall = try #require(VideoAnnotationGeometry.videoRect(image: CGSize(width: 1080,height: 1920),canvas: CGRect(x: 0,y: 0,width: 500,height: 300)))
        #expect(tall.minX > 0 && tall.minY == 0)
        let clipped = try #require(VideoAnnotationGeometry.drawn(from: wide.origin,to: .init(x: 2000,y: 2000),kind: .ellipse,video: wide))
        #expect(clipped.x == 0 && clipped.y == 0 && abs(clipped.width-1)<1e-9 && abs(clipped.height-1)<1e-9)
    }
    @Test func circleHasEqualPixelDiametersAndInvalidNumericBoundsRefuse() throws {
        let video = CGRect(x: 0,y: 0,width: 1920,height: 1080)
        let bounds = try #require(VideoAnnotationGeometry.drawn(from: .init(x: 200,y: 200),to: .init(x: 600,y: 500),kind: .circle,video: video))
        let shape = FrameEllipse(id: UUID(),kind: .circle,bounds: bounds)
        try shape.validate(width: 1920,height: 1080)
        #expect(abs(bounds.width*1920-bounds.height*1080)<1e-9)
        #expect(throws: (any Error).self) { try FrameEllipse(id: UUID(),kind: .circle,bounds: .init(x: 0,y: 0,width: 0.2,height: 0.2)).validate(width: 1920,height: 1080) }
        for bad in [Double.nan,Double.infinity,-0.1,2] { #expect(throws: (any Error).self) { try NormalizedVideoRect(x: bad,y: 0,width: 0.1,height: 0.1).validate() } }
    }
    @Test func eachMarkIsOneUndoAndDivergentEditClearsRedo() throws {
        var history = FrameAnnotationHistory()
        let shape = FrameEllipse(id: UUID(),kind: .ellipse,bounds: .init(x: 0.1,y: 0.1,width: 0.2,height: 0.2))
        try history.add(shape); history.undo(); #expect(history.shapes.isEmpty && history.canRedo)
        history.redo(); #expect(history.shapes == [shape])
        try history.remove(shape.id); history.undo(); #expect(history.shapes == [shape])
        history.undo(); try history.add(.init(id: UUID(),kind: .ellipse,bounds: shape.bounds)); #expect(!history.canRedo)
    }
    @Test func exactBFrameExtractionAndRevisionPreserveImageSourceAndCurrent() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let current = f.project.folder.appendingPathComponent("cuts/current.json"), sentinel = Data("Untouched current sentinel".utf8); try sentinel.write(to: current)
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        #expect(frozen.width == 160 && frozen.height == 90 && frozen.actualTime.value == 12012)
        let repo = FrameCommentRepository(project: f.project)
        let shape = FrameEllipse(id: UUID(),kind: .ellipse,bounds: .init(x: 0.2,y: 0.2,width: 0.3,height: 0.3))
        let first = try await repo.save(frame: frozen,text: "Review this detail",annotations: [shape])
        let second = try await repo.save(frame: frozen,text: "Keep this detail visible",annotations: [],supersedes: first.id)
        #expect(try await repo.list().map(\.id) == [second.id])
        #expect(try await repo.read(first.id).1.png == frozen.png)
        #expect(try await repo.read(second.id).0.supersedesID == first.id)
        #expect(second.reviewOnly && !second.productionAuthorized && !second.appliedToVideo)
        #expect(try Data(contentsOf: current) == sentinel)
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == f.target.preview.sha256)
        await #expect(throws: (any Error).self) { try await repo.save(frame: frozen,text: "",annotations: [shape]) }
    }
    @Test func displayedFramePixelsMatchIndependentDecoderAndDifferFromNeighbors() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(frame: 12),project: f.project)
        func pixels(_ data: Data) throws -> [UInt8] {
            let source = try #require(CGImageSourceCreateWithData(data as CFData,nil)), image = try #require(CGImageSourceCreateImageAtIndex(source,0,nil))
            var bytes = [UInt8](repeating: 0,count: image.width*image.height*4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
            }
            return bytes
        }
        let actual = try pixels(frame.png)
        var differences: [Double] = []
        for index in [11,12,13] {
            let output = f.root.appendingPathComponent("independent-\(index).png")
            let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),arguments: ["-v","error","-nostdin","-n","-i",f.project.folder.appendingPathComponent(f.target.preview.relativePath).path,"-vf","select=eq(n\\,\(index))","-frames:v","1",output.path]))
            #expect(result.succeeded)
            let expected = try pixels(Data(contentsOf: output))
            #expect(actual.count == expected.count)
            differences.append(zip(actual,expected).enumerated().filter { $0.offset%4 != 3 }.map { abs(Double($0.element.0)-Double($0.element.1)) }.reduce(0,+)/Double(frame.width*frame.height*3))
        }
        #expect(differences[1] < 2)
        #expect(differences[0] > differences[1]+3 && differences[2] > differences[1]+3)
    }
    @Test func stableSaveIDRecoversAcknowledgementAndRefusesForkedRevisions() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), repo = FrameCommentRepository(project: f.project), operation = UUID()
        let first = try await repo.save(frame: frozen,text: "One explicit save",annotations: [],id: operation)
        let before = try Data(contentsOf: f.project.folder.appendingPathComponent("notes/frame-comments/"+operation.uuidString+"/comment.json"))
        let acknowledged = try await repo.save(frame: frozen,text: "One explicit save",annotations: [],id: operation)
        #expect(acknowledged.id == first.id && acknowledged.request == first.request && acknowledged.text == first.text)
        // JSON epoch-millisecond dates can round by one floating-point ULP.
        #expect(abs(acknowledged.created.timeIntervalSince(first.created)) < 0.000001)
        #expect(try Data(contentsOf: f.project.folder.appendingPathComponent("notes/frame-comments/"+operation.uuidString+"/comment.json")) == before)
        #expect(try await repo.list().count == 1)
        let revised = try await repo.save(frame: frozen,text: "New revision",annotations: [],supersedes: first.id)
        await #expect(throws: (any Error).self) { try await repo.save(frame: frozen,text: "Stale competing revision",annotations: [],supersedes: first.id) }
        #expect(try await repo.list().map(\.id) == [revised.id])
        await #expect(throws: (any Error).self) { try await repo.save(frame: frozen,text: "Different payload",annotations: [],id: operation) }
    }
    @Test func saveRefusesChangedSourceAndIgnoresIncompleteBundle() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), repo = FrameCommentRepository(project: f.project)
        let folder = f.project.folder.appendingPathComponent("notes/frame-comments/"+UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        try Data("Incomplete".utf8).write(to: folder.appendingPathComponent("comment.json"))
        #expect(try await repo.list().isEmpty)
        try Data("Mutated original".utf8).write(to: f.project.folder.appendingPathComponent(f.target.preview.relativePath))
        await #expect(throws: (any Error).self) { try await repo.save(frame: frozen,text: "Cannot attach to changed source",annotations: []) }
        #expect(try await repo.list().isEmpty)
    }
    @Test func tamperedSavedPNGAndSymlinkNotesRefuse() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), repo = FrameCommentRepository(project: f.project)
        let saved = try await repo.save(frame: frozen,text: "Synthetic note",annotations: [])
        let png = f.project.folder.appendingPathComponent("notes/frame-comments/"+saved.id.uuidString+"/frame.png")
        try Data("Corrupt PNG".utf8).write(to: png)
        await #expect(throws: (any Error).self) { try await repo.read(saved.id) }
        await #expect(throws: (any Error).self) { try await repo.list() }
        try FileManager.default.moveItem(at: f.project.folder.appendingPathComponent("notes"),to: f.root.appendingPathComponent("moved-notes"))
        try FileManager.default.createSymbolicLink(at: f.project.folder.appendingPathComponent("notes"),withDestinationURL: f.root.appendingPathComponent("moved-notes"))
        await #expect(throws: (any Error).self) { try await repo.save(frame: frozen,text: "Do not follow symlink",annotations: []) }
    }
    @MainActor @Test func cancelLateCaptureThenNewCommentCannotReceiveOldFrameOrLoseNewTask() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let controller = FrameCommentController(project: f.project,capture: DelayedFrameCapture(frozen))
        let first = try f.request(frame: 3); try controller.begin(first)
        await Task.yield(); #expect(controller.cancel())
        let second = try f.request(frame: 20); try controller.begin(second)
        try await Task.sleep(for: .milliseconds(250))
        #expect(controller.draft?.request == second && controller.draft?.frame?.request == second && !controller.preparing)
        #expect(!(await controller.flushForExit()))
        #expect(controller.cancel()); #expect(await controller.flushForExit())
        #expect(try await controller.repository.list().isEmpty)
    }
    @MainActor @Test func cancelBeforeSavedEditTaskStartsNeverResurrectsDraft() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let controller = FrameCommentController(project: f.project)
        let saved = try await controller.repository.save(frame: frozen,text: "Saved comment",annotations: [])
        try controller.beginEdit(saved)
        #expect(controller.hasPendingWork && controller.preparing)
        #expect(controller.cancel())
        #expect(await controller.flushForExit())
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.draft == nil && !controller.preparing && !controller.hasPendingWork)
    }
    @MainActor @Test func doubleSaveCoalescesAndFrameEditorLeaseBlocksCaptureAndCandidatePlayer() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let controller = FrameCommentController(project: f.project,capture: DelayedFrameCapture(frozen))
        let voice = try VoiceReviewController(project: f.project,provider: SyntheticVoiceReviewProvider()), lease = UUID()
        #expect(voice.beginFrameComment(lease)); #expect(!voice.canPresentCandidate && !voice.canStart)
        #expect(!voice.beginCandidatePlayback(UUID()))
        try controller.begin(f.request()); controller.releaseLease = { voice.endFrameComment(lease) }
        try await Task.sleep(for: .milliseconds(150)); controller.draft?.text = "Written frame feedback"
        async let one = controller.save(); async let two = controller.save()
        #expect(await one); #expect(await two)
        #expect(try await controller.repository.list().count == 1)
        #expect(controller.draft == nil && voice.frameCommentLease == nil && voice.canPresentCandidate)
    }
}
