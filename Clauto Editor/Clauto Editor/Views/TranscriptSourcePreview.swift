import SwiftUI
import AVFoundation
import Observation

/// No system transport: only bounded forward play and passage-relative seeking.
@MainActor @Observable private final class TranscriptSourceTransport {
    private(set) var player: AVPlayer?
    private(set) var position = 0.0
    private(set) var ready = false
    private(set) var playing = false
    private(set) var failure: String?
    private var ticket: VerifiedSourcePlayback?
    private var validate: (() async throws -> Void)?
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var generation = UUID()
    private var seeking = false

    func open(_ ticket: VerifiedSourcePlayback, validate: @escaping () async throws -> Void) async {
        stop(); self.ticket = ticket; self.validate = validate
        let token = generation
        do {
            try await validate()
            guard generation == token, !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: SourceMediaVerifier.asset(at: URL(fileURLWithPath: ticket.media.canonicalPath)))
            item.forwardPlaybackEndTime = CMTime(seconds: ticket.span.sourceOut, preferredTimescale: 60_000)
            let player = AVPlayer(playerItem: item); player.actionAtItemEnd = .pause; self.player = player
            itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    if status == .failed { fail("The verified source could not be opened for playback.") }
                    else if status == .readyToPlay && !ready && !seeking { await seek(0) }
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                let seconds = time.seconds
                Task { @MainActor [weak self] in
                    guard let self, generation == token, ready, !seeking else { return }
                    if !seconds.isFinite || seconds < ticket.span.sourceIn - 0.001 || seconds > ticket.span.sourceOut + 0.001 || (self.player?.rate ?? 0) < 0 {
                        fail("Playback moved outside this source passage. Verify it again."); return
                    }
                    position = min(ticket.span.duration, max(0, seconds - ticket.span.sourceIn))
                    playing = self.player?.rate == 1
                }
            }
            while !Task.isCancelled, generation == token, failure == nil {
                try await Task.sleep(for: .milliseconds(500))
                try await validate()
            }
        } catch is CancellationError { }
        catch { if generation == token { fail(error.localizedDescription) } }
    }

    func toggle() async {
        if playing { player?.pause(); playing = false; return }
        guard ready, !seeking, let ticket, let validate else { return }
        let token = generation
        do {
            try await validate()
            guard generation == token, failure == nil else { return }
            if position >= ticket.span.duration - 0.001 { await seek(0) }
            guard generation == token, ready, !seeking, failure == nil else { return }
            try await validate()
            guard generation == token, failure == nil else { return }
            player?.playImmediately(atRate: 1); playing = true
        } catch { if generation == token { fail(error.localizedDescription) } }
    }

    func seek(_ relative: Double) async {
        guard let ticket, let player, !seeking, failure == nil, relative.isFinite,
              relative >= 0, relative <= ticket.span.duration else { return }
        let token = generation
        player.pause(); playing = false; seeking = true; ready = false
        let completed = await player.seek(to: CMTime(seconds: ticket.span.sourceIn + relative, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        guard generation == token else { return }
        seeking = false
        guard completed else { fail("The source passage seek did not complete. Verify it again."); return }
        position = relative; ready = true
    }
    private func fail(_ message: String) { player?.pause(); playing = false; ready = false; failure = message }
    func stop() {
        generation = UUID(); player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil; itemObserver = nil; player = nil; ticket = nil; validate = nil
        ready = false; playing = false; seeking = false; position = 0; failure = nil
    }
}

private struct TranscriptSourceCanvas: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> ClautoVideoCanvas { ClautoVideoCanvas(frame: .zero) }
    func updateNSView(_ view: ClautoVideoCanvas, context: Context) { view.player = player }
    static func dismantleNSView(_ view: ClautoVideoCanvas, coordinator: ()) { view.player?.pause(); view.player = nil }
}

struct TranscriptSourcePreview: View {
    @Bindable var controller: TranscriptReviewController
    let ticket: VerifiedSourcePlayback
    @State private var transport = TranscriptSourceTransport()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptSourceCanvas(player: transport.player).aspectRatio(16/9, contentMode: .fit).background(ClautoDesign.ink)
            if let failure = transport.failure {
                Text(failure).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
            } else {
                HStack(spacing: 10) {
                    ClautoAction(transport.playing ? "Pause" : "Play passage", icon: transport.playing ? .pause : .play, kind: .primary) {
                        Task { await transport.toggle() }
                    }.disabled(!transport.ready)
                    Text(String(format: "%.2f / %.2f s", transport.position, ticket.span.duration)).font(ClautoDesign.caption.monospacedDigit())
                }
                ClautoSlider(value: Binding(get: { transport.position }, set: { value in Task { await transport.seek(value) } }),
                    range: 0...ticket.span.duration, label: "Source passage playhead").disabled(!transport.ready)
            }
            Text("Media verified at check time. Playback pauses if a changed file or review is detected; the player does not hold an immutable copy.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            Text(ticket.media.transcriptSnapshotVerified ? "Original transcript snapshot verified." : "Media-only preview · original transcript snapshot unavailable.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
        }.task(id: ticket.id) { await transport.open(ticket) { try await controller.validatePlayback(ticket) } }
            .onDisappear { transport.stop() }
    }
}
