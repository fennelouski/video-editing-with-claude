import SwiftUI
import AVKit
import Observation

/// Store-owned clock and provenance. Moving or rebuilding a surface never
/// disposes this session, its player, observer or voice binding.
@MainActor @Observable final class ReviewPlayerSession {
    let id = UUID()
    let ownerID: UUID
    let project: Project
    let version: CutVersion
    let url: URL
    let player: AVPlayer
    let control = ReviewPlaybackControl()
    private(set) var endpoint: ReviewPlaybackEndpoint?
    private(set) var playhead = 0.0
    private(set) var ready = false
    private(set) var playing = false
    private(set) var rate = 0.0
    var issue: String?
    var presentationNotice: String?
    @ObservationIgnored weak var store: EditorStore?
    @ObservationIgnored weak var router: ReviewWindowRouter?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var clockObserver: Any?
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    private(set) var workspaceVisible = false
    private var disposed = false
    private var ownerClosed = false
    private var returningToWorkspace = false
    @ObservationIgnored private var preparing: Task<Void,Never>?
    @ObservationIgnored private var binding: Task<Void,Never>?
    @ObservationIgnored lazy var presentation = ReviewVideoPresentation(session: self)
    init(project: Project,version: CutVersion,url: URL,store: EditorStore,ownerID: UUID) {
        self.ownerID = ownerID
        self.project = project; self.version = version; self.url = url; self.store = store
        player = AVPlayer(url: url); control.player = player
        control.onSeekRequested = { [weak self] in self?.record(.seekRequested) }
        control.onSeekCompleted = { [weak self] completed in self?.record(completed ? .seekCompleted : .unavailable) }
        observations.append(player.currentItem!.observe(\.status,options: [.initial,.new]) { [weak self] _,_ in let session = self; Task { @MainActor in session?.refresh() } })
        observations.append(player.observe(\.rate,options: [.initial,.new]) { [weak self] _,_ in let session = self; Task { @MainActor in session?.refresh() } })
        observations.append(player.observe(\.timeControlStatus,options: [.initial,.new]) { [weak self] _,_ in let session = self; Task { @MainActor in session?.refresh() } })
        clockObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1,preferredTimescale: 600),queue: .main) { [weak self] _ in let session = self; Task { @MainActor in session?.refresh() } }
        jumpObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped,object: player.currentItem,queue: .main) { [weak self] _ in let session = self; Task { @MainActor in session?.record(session?.control.seeking == true ? .seekRequested : .unavailable) } }
    }
    var duration: Double { endpoint?.target.duration ?? 0 }
    var voice: VoiceReviewController? { store?.voiceReviews[project.id] }
    func attach(to router: ReviewWindowRouter) {
        guard !disposed, router.id == ownerID else { return }
        self.router = router; router.inlineEndpointID = id; workspaceVisible = true; returningToWorkspace = false
        if let endpoint { router.register(endpoint); if router.intendedVersionID == version.id { router.select(id) }; return }
        guard preparing == nil, let store else { return }
        preparing = Task { [weak self] in
            guard let self else { return }
            defer { self.preparing = nil }
            do {
                let target = try await store.playbackTarget(version: self.version,project: self.project)
                guard !self.disposed else { return }
                self.endpoint = .init(id: self.id,project: self.project,target: target,driver: self.control)
                if let endpoint = self.endpoint, self.workspaceVisible || self.presentation.detached { self.router?.register(endpoint); if self.router?.intendedVersionID == self.version.id { self.router?.select(self.id) } }
                await store.frameComment(for: self.project).load()
                await store.voiceReview(for: self.project)?.load()
                // Voice binding is explicit (Use this video); a background load cannot retarget capture.
            } catch { self.issue = error.localizedDescription }
        }
    }
    func selectForVoice() {
        guard binding == nil, let store, let voice = store.voiceReview(for: project) else { return }
        voice.willAttach(id)
        binding = Task { [weak self] in
            guard let self else { return }; defer { self.binding = nil }
            guard !self.disposed, self.workspaceVisible || self.presentation.ownsExternalSurface else { return }
            await store.bindVoiceReview(version: self.version,project: self.project,token: self.id,sampler: { [weak self] in self?.sample() ?? .init(host: VoiceLivePlayhead.now,seconds: 0,rate: 0,available: false) })
        }
    }
    func sample() -> VoiceLivePlayhead {
        let seconds = player.currentTime().seconds
        return .init(host: VoiceLivePlayhead.now,seconds: seconds.isFinite ? max(0,seconds) : 0,
                     rate: player.timeControlStatus == .playing ? Double(player.rate) : 0,
                     available: ready && !control.seeking && issue == nil && seconds.isFinite && seconds >= 0 && seconds <= duration)
    }
    func record(_ kind: VoiceTransportKind = .sample) { voice?.record(sample(),kind: kind,token: id) }
    private func refresh() {
        ready = player.currentItem?.status == .readyToPlay
        playing = player.timeControlStatus == .playing; rate = playing ? Double(player.rate) : 0
        let seconds = player.currentTime().seconds
        if seconds.isFinite { playhead = max(0,seconds) }
        if player.currentItem?.status == .failed { player.pause(); issue = "Preview unavailable. Reconnect its drive, then reopen this version." }
        record()
    }
    func leaveWorkspace() {
        workspaceVisible = false; if router?.inlineEndpointID == id { router?.inlineEndpointID = nil }; presentation.releaseInlineHost()
        presentationDidEnd()
    }
    func ownerDidClose() { ownerClosed = true; leaveWorkspace() }
    func presentationDidEnd() {
        guard !workspaceVisible, !returningToWorkspace, !presentation.ownsExternalSurface else { return }
        control.pause(); router?.unregister(id); voice?.detach(id)
        if ownerClosed { dispose(); store?.reviewPlayers.removeValue(forKey: id) }
    }
    @discardableResult func returnToWorkspace() -> Bool {
        guard !disposed, !ownerClosed, let router, let window = router.window, let store else { return false }
        returningToWorkspace = true; router.returnVersionID = version.id
        store.selectedID = project.id; router.tab = "Cut"; window.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.returningToWorkspace else { return }
            self.returningToWorkspace = false; self.presentationDidEnd()
        }
        return true
    }
    func invoke(_ command: EditorCommand) {
        guard !disposed, let router else { return }
        router.select(id); router.perform(command,explicitControl: true)
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        preparing?.cancel(); binding?.cancel(); control.pause(); presentation.dispose()
        if let clockObserver { player.removeTimeObserver(clockObserver) }; clockObserver = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }; jumpObserver = nil
        observations.removeAll(); control.detach(player); voice?.detach(id); router?.unregister(id)
    }
}

@MainActor final class ReviewVideoClickSurface: NSView {
    weak var presentation: ReviewVideoPresentation?
    private var down: NSPoint?
    private var moved = false
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard let session = presentation?.session, session.ready else { return false }; session.invoke(.toggle); return true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); down = event.locationInWindow; moved = false
        if let session = presentation?.session { session.router?.select(session.id) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        if hypot(event.locationInWindow.x-down.x,event.locationInWindow.y-down.y) > 6 {
            moved = true
            if presentation?.detached == true && window?.styleMask.contains(.fullScreen) != true { window?.performDrag(with: event) }
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        guard let down, hypot(event.locationInWindow.x-down.x,event.locationInWindow.y-down.y) <= 6, !moved, bounds.contains(convert(event.locationInWindow,from: nil)) else { return }
        presentation?.session?.invoke(.toggle)
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty, window?.attachedSheet == nil else { super.keyDown(with: event); return }
        let command: EditorCommand?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": command = .toggle
        case "j": command = .reverse
        case "k": command = .stop
        case "l": command = .play
        case ",": command = .previousFrame
        case ".": command = .nextFrame
        case "\u{1b}": presentation?.escape(); return
        default: command = nil
        }
        if let command { presentation?.session?.invoke(command) } else { super.keyDown(with: event) }
    }
}

/// A single AVPlayerView is reparented; no duplicate render layers/audio clocks.
@MainActor @Observable final class ReviewVideoPresentation: NSObject, NSWindowDelegate, AVPlayerViewPictureInPictureDelegate {
    weak var session: ReviewPlayerSession?
    private(set) var detached = false
    private(set) var pipActive = false
    private(set) var pipStarting = false
    var ownsExternalSurface: Bool { detached || pipActive || pipStarting }
    private enum Transition { case stable, entering, exiting }
    private var transition = Transition.stable
    let surface = NSView()
    let native = AVPlayerView()
    let gestures = ReviewVideoClickSurface()
    @ObservationIgnored weak var inlineHost: NSView?
    @ObservationIgnored private(set) var videoWindow: NSWindow?
    @ObservationIgnored private var savedFrame: NSRect?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var dockingAfterFullScreen = false
    @ObservationIgnored private var retainedRouter: ReviewWindowRouter?
    private(set) var generation = UUID()
    init(session: ReviewPlayerSession) {
        self.session = session; super.init()
        surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor.black.cgColor
        native.player = session.player; native.controlsStyle = .none; native.allowsPictureInPicturePlayback = true
        native.showsFullScreenToggleButton = false; native.pictureInPictureDelegate = self
        gestures.presentation = self; gestures.setAccessibilityElement(true); gestures.setAccessibilityRole(.button)
        gestures.setAccessibilityLabel("Video. Click or Space to play or pause. J K L shuttle; comma and period step frames.")
        for view in [native,gestures] { view.frame = surface.bounds; view.autoresizingMask = [.width,.height]; surface.addSubview(view) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,object: nil,queue: .main) { [weak self] _ in let presentation = self; Task { @MainActor in presentation?.recoverScreen() } }
    }
    func releaseInlineHost() { inlineHost = nil }
    func unmount(_ host: NSView) { if inlineHost === host { inlineHost = nil } }
    func dispose() {
        generation = UUID(); retainedRouter = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        native.pictureInPictureDelegate = nil; native.player = nil
        videoWindow?.delegate = nil; videoWindow?.contentView = nil; videoWindow?.orderOut(nil); videoWindow = nil
        surface.removeFromSuperview()
    }
    func mount(_ host: NSView) {
        inlineHost = host
        if !detached { reparent(to: host) }
    }
    func mountDetached(_ host: NSView,generation: UUID) {
        guard detached, self.generation == generation, host.window === videoWindow else { return }; reparent(to: host)
    }
    private func reparent(to host: NSView) { guard surface.superview !== host else { return }; surface.removeFromSuperview(); surface.frame = host.bounds; surface.autoresizingMask = [.width,.height]; host.addSubview(surface) }
    func toggleDetach() { detached ? dock() : detach() }
    func detach(showWindow: Bool = true) {
        guard !detached, !pipActive, !pipStarting, let session else { return }
        let window = ReviewDetachedWindow(contentRect: NSRect(x: 0,y: 0,width: 960,height: 580),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        generation = UUID(); retainedRouter = session.router
        window.presentation = self
        window.title = "\(session.project.manifest.name) · v\(session.version.number)"
        window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 420,height: 280)
        videoWindow = window; detached = true
        let host = NSHostingView(rootView: DetachedReviewVideo(session: session,presentation: self,generation: generation))
        window.contentView = host; window.center()
        if showWindow { window.makeKeyAndOrderFront(nil) }
        if let router = session.router { PlaybackMenuCoordinator.shared.register(window,router: router,primary: false) }
    }
    func dock() {
        guard detached else { return }
        guard !pipActive, !pipStarting else { session?.presentationNotice = "Close native Picture in Picture before re-embedding the video."; return }
        if transition == .entering { dockingAfterFullScreen = true; return }
        if transition == .exiting { dockingAfterFullScreen = true; return }
        if videoWindow?.styleMask.contains(.fullScreen) == true {
            dockingAfterFullScreen = true; transition = .exiting; videoWindow?.toggleFullScreen(nil); return
        }
        let old = videoWindow; detached = false; generation = UUID()
        if let inlineHost, session?.workspaceVisible == true { reparent(to: inlineHost) }
        else { surface.removeFromSuperview(); if session?.returnToWorkspace() != true { session?.control.pause() } }
        if let old, let router = session?.router { PlaybackMenuCoordinator.shared.unregister(old,router: router) }
        old?.delegate = nil; old?.contentView = nil; old?.orderOut(nil); videoWindow = nil; session?.presentationDidEnd(); if !ownsExternalSurface { retainedRouter = nil }
    }
    func toggleFullScreen() {
        if !detached { detach() }
        guard let window = videoWindow, transition == .stable, !pipActive, !pipStarting else { return }
        if !window.styleMask.contains(.fullScreen) { savedFrame = window.frame; transition = .entering } else { transition = .exiting }
        window.toggleFullScreen(nil)
    }
    func escape() { if videoWindow?.styleMask.contains(.fullScreen) == true { toggleFullScreen() } else if detached { dock() } }
    func showNativeControls() { native.controlsStyle = .inline; gestures.isHidden = true }
    func hideNativeControls() { native.controlsStyle = .none; gestures.isHidden = false }
    func focus() { if let session { session.router?.select(session.id) }; surface.window?.makeFirstResponder(gestures) }
    func windowDidBecomeKey(_ notification: Notification) { if let session { session.router?.select(session.id) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dock(); return false }
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === videoWindow else { return }; transition = .stable
        if dockingAfterFullScreen { transition = .exiting; videoWindow?.toggleFullScreen(nil) }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { guard window === videoWindow else { return }; transition = .stable; if dockingAfterFullScreen { dockingAfterFullScreen = false; dock() } }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { guard window === videoWindow else { return }; transition = .stable; dockingAfterFullScreen = false; session?.presentationNotice = "Full screen could not close. Use the video window's green button to retry." }
    func windowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === videoWindow else { return }; transition = .stable
        if let savedFrame { videoWindow?.setFrame(savedFrame,display: true) }; recoverScreen()
        if dockingAfterFullScreen { dockingAfterFullScreen = false; dock() }
    }
    func playerViewWillStartPicture(inPicture view: AVPlayerView) { session?.presentationNotice = nil; retainedRouter = session?.router; pipStarting = true }
    func playerViewDidStartPicture(inPicture view: AVPlayerView) { pipStarting = false; pipActive = true }
    func playerView(_ view: AVPlayerView,failedToStartPictureInPictureWithError error: Error) { pipStarting = false; pipActive = false; session?.presentationNotice = error.localizedDescription; session?.presentationDidEnd(); if !ownsExternalSurface { retainedRouter = nil } }
    func playerViewDidStopPicture(inPicture view: AVPlayerView) { session?.presentationNotice = nil; pipStarting = false; pipActive = false; session?.presentationDidEnd(); if !ownsExternalSurface { retainedRouter = nil } }
    func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart view: AVPlayerView) -> Bool { false }
    func playerView(_ view: AVPlayerView,restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        if let window = surface.window { window.makeKeyAndOrderFront(nil); completion(true); return }
        guard let router = session?.router, router.window != nil else { completion(false); return }
        guard session?.returnToWorkspace() == true else { completion(false); return }
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                if let window = self?.surface.window { window.makeKeyAndOrderFront(nil); completion(true); return }
                try? await Task.sleep(for: .milliseconds(25))
            }
            completion(false)
        }
    }
    private func recoverScreen() {
        guard let window = videoWindow, !window.styleMask.contains(.fullScreen), let screen = NSScreen.screens.max(by: { a,b in window.frame.intersection(a.visibleFrame).area < window.frame.intersection(b.visibleFrame).area }) else { return }
        var frame = window.frame; let bounds = screen.visibleFrame
        frame.size.width = min(frame.width,bounds.width); frame.size.height = min(frame.height,bounds.height)
        frame.origin.x = min(max(frame.minX,bounds.minX),bounds.maxX-frame.width)
        frame.origin.y = min(max(frame.minY,bounds.minY),bounds.maxY-frame.height)
        window.setFrame(frame,display: true)
    }
}
private extension NSRect { var area: CGFloat { isNull ? 0 : width*height } }

struct StableReviewVideo: NSViewRepresentable {
    let presentation: ReviewVideoPresentation
    var detachedHost = false
    var detachedGeneration: UUID? = nil
    @MainActor final class Coordinator {
        weak var presentation: ReviewVideoPresentation?
        let generation: UUID
        init(_ presentation: ReviewVideoPresentation) { self.presentation = presentation; generation = presentation.generation }
    }
    final class Host: NSView {
        weak var presentation: ReviewVideoPresentation?
        var detachedGeneration: UUID?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let generation = detachedGeneration { presentation?.mountDetached(self,generation: generation) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(presentation) }
    func makeNSView(context: Context) -> Host { let host = Host(); host.presentation = presentation; host.detachedGeneration = detachedGeneration; return host }
    func updateNSView(_ host: Host,context: Context) {
        if detachedHost {
            if let detachedGeneration { presentation.mountDetached(host,generation: detachedGeneration) }
        }
        else if !detachedHost, context.coordinator.generation == presentation.generation { presentation.mount(host) }
    }
    static func dismantleNSView(_ view: Host,coordinator: Coordinator) { coordinator.presentation?.unmount(view) }
}
@MainActor private final class ReviewDetachedWindow: NSWindow {
    weak var presentation: ReviewVideoPresentation?
    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil, !PlaybackMenuCoordinator.isTextEditing(firstResponder) else { super.cancelOperation(sender); return }
        presentation?.escape()
    }
}
private struct DetachedReviewVideo: View {
    let session: ReviewPlayerSession
    let presentation: ReviewVideoPresentation
    let generation: UUID
    @State private var controls = true
    @State private var hovering = false
    @State private var idle: Task<Void,Never>?
    @FocusState private var focused: EditorCommand?
    var body: some View {
        VStack(spacing: 0) {
            StableReviewVideo(presentation: presentation,detachedHost: true,detachedGeneration: generation).frame(maxWidth: .infinity,maxHeight: .infinity)
            HStack {
                Button(session.playing ? "Pause" : "Play") { session.invoke(.toggle) }.focused($focused,equals: .toggle)
                Text(String(format: "%.3fs",session.playhead)).monospacedDigit().textSelection(.enabled)
                Spacer()
                Button("PiP Controls") { presentation.showNativeControls() }.focused($focused,equals: .pictureInPicture)
                Button("Full Screen") { presentation.toggleFullScreen() }.focused($focused,equals: .fullScreen)
                Button("Re-embed") { presentation.dock() }.focused($focused,equals: .detach)
            }.padding(10).opacity(controls ? 1 : 0).allowsHitTesting(controls)
                .onHover { hovering = $0; reveal() }
        }.background(.black).foregroundStyle(.white)
            .onContinuousHover { _ in reveal() }.onChange(of: focused) { reveal() }.onChange(of: session.playing) { reveal() }
            .onAppear { reveal() }.onDisappear { idle?.cancel() }
    }
    private func reveal() {
        controls = true; idle?.cancel()
        guard session.playing, focused == nil, !hovering else { return }
        idle = Task { try? await Task.sleep(for: .seconds(2.5)); if !Task.isCancelled, !(presentation.videoWindow?.firstResponder is NSTextInputClient) { controls = false } }
    }
}
