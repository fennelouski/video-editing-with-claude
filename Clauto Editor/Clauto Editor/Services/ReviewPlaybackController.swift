import Foundation
import AVFoundation
import Observation

@MainActor @Observable final class ReviewPlaybackPreferences {
    static let key = "ClautoPlaybackSkipSeconds"
    static func valid(_ value: Double) -> Bool { value.isFinite && value >= 1 && value <= 60 }
    private let defaults: UserDefaults
    private(set) var skipSeconds: Double
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.key) as? Double
        skipSeconds = saved.flatMap { Self.valid($0) ? $0 : nil } ?? 5
    }
    func setSkip(_ value: Double) throws {
        guard Self.valid(value) else { throw WorkflowFailure.invalid("Choose a skip interval from 1 to 60 seconds.") }
        skipSeconds = value; defaults.set(value,forKey: Self.key)
    }
}
@MainActor protocol ReviewPlaybackDriving: AnyObject {
    var ready: Bool { get }
    var seeking: Bool { get }
    var clock: ReviewClockTime? { get }
    func pause()
    func toggle()
    func seek(seconds: Double)
}
@MainActor @Observable final class ReviewPlaybackControl: ReviewPlaybackDriving {
    @ObservationIgnored weak var player: AVPlayer?
    private(set) var seeking = false
    @ObservationIgnored private var seekID = UUID()
    @ObservationIgnored private var resumeSeekID: UUID?
    @ObservationIgnored var onSeekRequested: (() -> Void)?
    @ObservationIgnored var onSeekCompleted: ((Bool) -> Void)?
    var ready: Bool { player?.currentItem?.status == .readyToPlay }
    var clock: ReviewClockTime? {
        guard let time = player?.currentTime(), time.isValid, time.isNumeric, time.epoch == 0, time.timescale > 0 else { return nil }
        return .init(value: time.value,timescale: time.timescale)
    }
    func pause() { resumeSeekID = nil; player?.pause() }
    func toggle() {
        guard ready, !seeking, let player else { return }
        if player.timeControlStatus != .paused { pause(); return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        // Container edit-list duration may round beyond the exact last-frame
        // end. Treat the final frame interval as replay, like the old control.
        if duration.isFinite, duration > 0, player.currentTime().seconds >= duration-1001.0/24000 {
            performSeek(seconds: 0,resume: true)
        } else { player.play() }
    }
    func seek(seconds: Double) { performSeek(seconds: seconds,resume: false) }
    private func performSeek(seconds: Double, resume: Bool) {
        guard ready, seconds.isFinite, seconds >= 0, let player else { return }
        let token = UUID(); seekID = token; resumeSeekID = resume ? token : nil; seeking = true; onSeekRequested?()
        player.seek(to: CMTime(seconds: seconds,preferredTimescale: 24000),toleranceBefore: .zero,toleranceAfter: .zero) { [weak self] finished in
            let control = self
            Task { @MainActor in
                guard let control, control.seekID == token else { return }
                control.seeking = false; control.onSeekCompleted?(finished)
                if finished, control.resumeSeekID == token { control.resumeSeekID = nil; control.player?.play() }
            }
        }
    }
    func detach(_ old: AVPlayer?) {
        guard player === old else { return }
        seekID = UUID(); resumeSeekID = nil; seeking = false; player = nil; onSeekRequested = nil; onSeekCompleted = nil
    }
}
@MainActor final class ReviewPlaybackEndpoint: Identifiable {
    let id: UUID
    let project: Project
    let target: VoiceReviewTarget
    let driver: any ReviewPlaybackDriving
    init(id: UUID, project: Project, target: VoiceReviewTarget, driver: any ReviewPlaybackDriving) {
        self.id = id; self.project = project; self.target = target; self.driver = driver
    }
    var ready: Bool { driver.ready && !driver.seeking }
    func skip(_ interval: Double) {
        guard ready, interval.isFinite, let clock = driver.clock, clock.timescale > 0 else { return }
        let seconds = Double(clock.value)/Double(clock.timescale)
        guard seconds.isFinite else { return }
        driver.seek(seconds: min(target.duration,max(0,seconds+interval)))
    }
    /// Synchronous: pause and freeze selected version/clock before any task or
    /// editor focus change. Async extraction can never choose another endpoint.
    func pauseAndFreeze() throws -> FrameCommentRequest {
        guard ready else { throw WorkflowFailure.invalid("Wait for this saved player and its seek to finish before commenting.") }
        driver.pause()
        guard let clock = driver.clock else { throw WorkflowFailure.invalid("The exact paused playback clock is unavailable.") }
        return .init(id: UUID(),target: target,frame: try .capture(clock,duration: target.duration))
    }
}
enum ReviewShortcutPolicy {
    static func permits(textEditing: Bool, modalPresented: Bool, selectedPlayerReady: Bool) -> Bool {
        !textEditing && !modalPresented && selectedPlayerReady
    }
}
