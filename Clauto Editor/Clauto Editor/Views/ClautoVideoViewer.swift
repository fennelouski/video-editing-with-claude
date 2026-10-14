import SwiftUI
import AVKit

private struct ClautoPlaybackSeek { var id = UUID(); var seconds: Double }

@MainActor private final class ClautoVideoHandle { weak var player: AVPlayer? }
private struct ClautoVideoSurface: NSViewRepresentable {
    var url: URL
    var handle: ClautoVideoHandle
    @Binding var position: Double
    @Binding var playing: Bool
    @Binding var ready: Bool
    @Binding var failure: String?
    var seek: ClautoPlaybackSeek?
    @MainActor final class Coordinator {
        var owner: ClautoVideoSurface
        var player: AVPlayer?
        var observer: Any?
        var lastSeek: UUID?
        var playbackObserver: NSKeyValueObservation?
        var itemObserver: NSKeyValueObservation?
        var generation = UUID()
        init(_ owner: ClautoVideoSurface) { self.owner = owner }
        func install(_ player: AVPlayer) {
            stop(); self.player = player; owner.handle.player = player
            lastSeek = nil
            let token = generation
            playbackObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let active = player.timeControlStatus != .paused
                let coordinator = self
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == token else { return }
                    coordinator.owner.playing = active && coordinator.owner.ready && coordinator.owner.failure == nil
                }
            }
            itemObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                let coordinator = self
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == token else { return }
                    coordinator.owner.ready = status == .readyToPlay
                    if status == .failed {
                        coordinator.player?.pause(); coordinator.owner.playing = false
                        coordinator.owner.failure = "This preview is unavailable. Reconnect its drive or reveal the verified export to check its file."
                    }
                }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                let seconds = time.seconds
                let coordinator = self
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == token, seconds.isFinite else { return }
                    coordinator.owner.position = max(0, seconds)
                }
            }
        }
        func stop() {
            if owner.handle.player === player { owner.handle.player = nil }
            if let observer { player?.removeTimeObserver(observer) }; observer = nil
            generation = UUID(); playbackObserver = nil; itemObserver = nil; lastSeek = nil; player?.pause(); player = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ClautoVideoCanvas {
        let view = ClautoVideoCanvas(frame: .zero)
        let player = AVPlayer(url: url); view.player = player; context.coordinator.install(player); return view
    }
    func updateNSView(_ view: ClautoVideoCanvas, context: Context) {
        context.coordinator.owner = self
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            let player = AVPlayer(url: url); view.player?.pause(); view.player = player; context.coordinator.install(player)
        }
        if let seek, context.coordinator.lastSeek != seek.id {
            context.coordinator.lastSeek = seek.id
            view.player?.seek(to: CMTime(seconds: seek.seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    static func dismantleNSView(_ view: ClautoVideoCanvas, coordinator: Coordinator) { coordinator.stop(); view.player = nil }
}

struct ClautoVideoViewer: View {
    let url: URL
    @State private var handle = ClautoVideoHandle()
    @State private var position = 0.0
    @State private var seek: ClautoPlaybackSeek?
    @State private var duration = 0.0
    @State private var playing = false
    @State private var loading = true
    @State private var ready = false
    @State private var playbackIssue: String?
    var body: some View {
        VStack(spacing: 10) {
            ClautoVideoSurface(url: url, handle: handle, position: $position, playing: $playing, ready: $ready, failure: $playbackIssue, seek: seek)
                .aspectRatio(16/9, contentMode: .fit).frame(maxHeight: 360).background(ClautoDesign.ink)
                .overlay { if playbackIssue != nil { ClautoUnavailablePreview() } }
            if loading || (!ready && playbackIssue == nil) { ClautoActivity(label: "Loading the local preview…") }
            if let playbackIssue { Text(playbackIssue).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                ClautoAction(playing ? "Pause" : "Play", icon: playing ? .pause : .play, kind: .primary) {
                    if playing { handle.player?.pause() } else {
                        if duration > 0 && position >= duration - 0.05 { seek = ClautoPlaybackSeek(seconds: 0) }
                        handle.player?.play()
                    }
                }.disabled(duration <= 0 || !ready)
                ClautoSlider(value: Binding(get: { position }, set: { seek = ClautoPlaybackSeek(seconds: $0) }), range: 0...max(1, duration), label: "Export playhead").disabled(duration <= 0 || !ready)
                Text(String(format: "%02d:%02d", Int(position)/60, Int(position)%60)).font(ClautoDesign.caption.monospacedDigit())
            }
        }.task(id: url) {
            loading = true; playbackIssue = nil; duration = 0; position = 0; seek = nil; playing = false; ready = false
            do {
                let time = try await AVURLAsset(url: url).load(.duration)
                guard !Task.isCancelled else { return }
                if time.seconds.isFinite, time.seconds > 0 {
                    duration = time.seconds
                    ready = handle.player?.currentItem?.status == .readyToPlay
                    if handle.player?.currentItem?.status == .failed {
                        handle.player?.pause(); playing = false
                        playbackIssue = "This preview is unavailable. Reconnect its drive or reveal the verified export to check its file."
                    }
                }
                else { playbackIssue = "The preview has no readable duration. Reveal the verified export and check its file." }
            } catch {
                guard !Task.isCancelled else { return }
                playbackIssue = "This preview is unavailable. Reconnect its drive or reveal the verified export to check its file."
            }
            loading = false
        }.onChange(of: position) { if duration > 0 && position >= duration - 0.05 { playing = false } }
    }
}

/// An AVPlayerLayer has no stock transport or missing-media glyph to show.
/// Player and observer ownership remains in the representable coordinator.
final class ClautoVideoCanvas: NSView {
    private let videoLayer = AVPlayerLayer()
    var player: AVPlayer? { get { videoLayer.player } set { videoLayer.player = newValue } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true; wantsLayer = true; layer?.masksToBounds = true; videoLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor(ClautoDesign.ink).cgColor; layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { super.init(coder: coder); clipsToBounds = true; wantsLayer = true; layer?.masksToBounds = true; layer?.addSublayer(videoLayer) }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds; CATransaction.commit()
    }
}
struct ClautoUnavailablePreview: View {
    var body: some View {
        VStack(spacing: 12) {
            ClautoIcon(.cut, size: 34).foregroundStyle(ClautoDesign.citron)
            Text("Preview unavailable").font(ClautoDesign.type(18, weight: .semibold)).foregroundStyle(ClautoDesign.paper)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ClautoDesign.ink)
    }
}
