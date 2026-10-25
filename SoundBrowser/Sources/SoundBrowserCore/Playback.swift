import Foundation
import AVFoundation

@MainActor public protocol SoundPlaying: AnyObject {
    func start(data: Data, volume: Float, finished: @escaping @MainActor () -> Void) throws
    func stop()
    func setVolume(_ volume: Float)
}

/// Construction and decoding do not play. Only the explicit Audition button
/// calls start; a verified immutable byte snapshot prevents path-swap playback.
@MainActor public final class NativeSoundPlayer: NSObject, SoundPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finished: (@MainActor () -> Void)?
    public override init() {}
    public func start(data: Data, volume: Float, finished: @escaping @MainActor () -> Void) throws {
        stop()
        let next = try AVAudioPlayer(data: data)
        next.volume = volume; next.delegate = self
        guard next.play() else { throw SoundFailure.invalid("The local audio output could not start. Check your output device.") }
        self.finished = finished; player = next
    }
    public func stop() { player?.stop(); player = nil; finished = nil }
    public func setVolume(_ volume: Float) { player?.volume = volume }
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let callback = finished; stop(); callback?()
    }
    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let callback = finished; stop(); callback?()
    }
}
