import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif
struct EditorCommandTests {
    @Test func exactNonDropTimecodeRoundTripAndRejection() throws {
        for frame in [0,23,24,1439,1440,86399,86400,2_073_599] {
            #expect(try ReviewTimecode.frame(ReviewTimecode.label(frame: frame)) == frame)
        }
        #expect(ReviewTimecode.seconds(frame: 24) == 1.001)
        for invalid in ["00:00:00:24","00:60:00:00","24:00:00:00","-1:00:00:00","00:00:00;00","1.5",":::","999999999999999999999999:00:00:00"] {
            #expect(throws: (any Error).self) { try ReviewTimecode.frame(invalid) }
        }
        #expect(Set(EditorCommand.allCases.map(\.id)).count == EditorCommand.allCases.count)
        #expect(EditorCommand.toggle.rawValue == 0 && EditorCommand.comment.rawValue == 3)
        #expect(EditorCommand.allCases.allSatisfy { !$0.title.isEmpty })
    }
    @Test func shuttleRatesMapMeasuredClockAndBreakCoverage() throws {
        for rate in [-4.0,-2,-1,0,1,2,4] {
            var session = VoiceReviewSession(id: UUID(),attemptID: UUID(),deviceUID: "synthetic",locale: "en-US",ownerProcessID: 0,created: Date())
            let target = UUID(), epoch = UUID()
            try session.observe(host: 100,seconds: 20,rate: rate,targetID: target,epoch: epoch,kind: .play)
            try session.observe(host: 101,seconds: 20+rate,rate: rate,targetID: target,epoch: epoch,kind: .sample)
            #expect(session.playhead.count == 1)
            #expect(session.playhead[0].time(at: 100.5) == 20+rate*0.5)
            let nextEpoch = UUID()
            try session.observe(host: 101,seconds: 20+rate,rate: 0,targetID: target,epoch: nextEpoch,kind: .rateChanged)
            try session.observe(host: 102,seconds: 20+rate,rate: 0,targetID: target,epoch: nextEpoch,kind: .sample)
            #expect(!session.coversPlayback(start: 100.5,end: 101.5,target: target,epoch: epoch))
            #expect(session.events.contains { $0.kind == .rateChanged })
        }
    }
    @MainActor @Test func frameStepPausesBeforeSamplingAndClampsExactLastFrame() async throws {
        let fixture = try await FrameReviewFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = try JSONEncoder().encode(fixture.target)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        object["duration"] = Double(31*1001)/24000
        let target = try JSONDecoder().decode(VoiceReviewTarget.self,from: JSONSerialization.data(withJSONObject: object))
        let driver = FakeReviewDriver()
        driver.value = .init(value: 30*1001,timescale: 24000)
        let endpoint = ReviewPlaybackEndpoint(id: UUID(),project: fixture.project,target: target,driver: driver)
        endpoint.step(1)
        #expect(driver.log == ["pause","clock"])
        #expect(driver.lastSeek == Double(30*1001)/24000)
        driver.seeking = false; driver.log = []; driver.value = .init(value: 0,timescale: 24000)
        endpoint.step(-1); #expect(driver.lastSeek == 0)
    }

    @MainActor @Test func unsavedTypedComposerSurvivesPaneAndVersionViewReplacement() async throws {
        let fixture = try await FrameReviewFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = try VoiceReviewController(project: fixture.project)
        let firstVersion = UUID(), otherVersion = UUID()
        var editor: VoiceTypedComposer? = controller.typedComposer(for: firstVersion)
        editor?.text = "Keep this unsaved idea"; editor?.start = "0.25"; editor?.end = "1.25"; editor?.action = .remove
        editor = nil // The pane's view disappears; the project owner remains.
        let other = controller.typedComposer(for: otherVersion); #expect(other.text.isEmpty)
        other.text = "Separate version draft"
        let restored = controller.typedComposer(for: firstVersion)
        #expect(restored.text == "Keep this unsaved idea" && restored.start == "0.25" && restored.end == "1.25" && restored.action == .remove)
        #expect(controller.document.notes.isEmpty && controller.document.candidates.isEmpty)
        #expect(controller.typedComposer(for: otherVersion).text == "Separate version draft")
    }

}
