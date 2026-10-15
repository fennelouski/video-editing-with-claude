import SwiftUI
import AppKit
import Observation

/// Per-window selection. A comparison player can only take ownership through
/// its own selection button or canvas; late-loading players never steal it.
@MainActor @Observable final class ReviewWindowRouter {
    private(set) var endpoints: [UUID: ReviewPlaybackEndpoint] = [:]
    private(set) var selectedID: UUID?
    var editor: FrameCommentController?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var store: EditorStore?
    func register(_ endpoint: ReviewPlaybackEndpoint) {
        endpoints[endpoint.id] = endpoint
        if selectedID == nil { selectedID = endpoint.id }
    }
    func unregister(_ id: UUID) {
        if let endpoint = endpoints[id], let editor, editor.preparing, editor.draft?.request.target == endpoint.target {
            _ = editor.cancel(); dismissEditor()
        }
        endpoints.removeValue(forKey: id)
        if selectedID == id { selectedID = nil }
    }
    func select(_ id: UUID) { if endpoints[id] != nil { selectedID = id } }
    var selected: ReviewPlaybackEndpoint? { selectedID.flatMap { endpoints[$0] } }
    var enabled: Bool {
        guard let window, window === NSApp.keyWindow else { return false }
        return ReviewShortcutPolicy.permits(textEditing: PlaybackMenuCoordinator.isTextEditing(window.firstResponder),
            modalPresented: window.attachedSheet != nil || NSApp.modalWindow != nil || editor != nil,
            selectedPlayerReady: selected?.ready == true)
    }
    func perform(_ command: PlaybackMenuCoordinator.Command) {
        guard enabled, let selected, let store else { return }
        switch command {
        case .toggle: selected.driver.toggle()
        case .back: selected.skip(-store.playbackPreferences.skipSeconds)
        case .forward: selected.skip(store.playbackPreferences.skipSeconds)
        case .comment: beginComment(selected)
        }
    }
    func beginComment(_ endpoint: ReviewPlaybackEndpoint) {
        guard editor == nil, endpoint.ready, let store else { return }
        let controller = store.frameComment(for: endpoint.project)
        guard !controller.hasPendingWork, let voice = store.voiceReview(for: endpoint.project) else {
            store.notice = "Finish or cancel this project's open frame comment first."; return
        }
        let lease = UUID()
        guard voice.beginFrameComment(lease) else { store.notice = voice.error; return }
        do {
            // No await or focus change before pausing and sampling the clock.
            let request = try endpoint.pauseAndFreeze()
            try controller.begin(request)
            controller.releaseLease = { [weak voice] in voice?.endFrameComment(lease) }
            editor = controller
        } catch { voice.endFrameComment(lease); store.notice = error.localizedDescription }
    }
    func dismissEditor() { editor = nil }
    func edit(_ record: SavedFrameComment, project: Project) {
        guard editor == nil, let store, let voice = store.voiceReview(for: project) else { return }
        let controller = store.frameComment(for: project), lease = UUID()
        guard !controller.hasPendingWork, voice.beginFrameComment(lease) else { store.notice = "Finish the open review or stop voice capture first."; return }
        selected?.driver.pause()
        do {
            // Reserve pending state before scheduling any disk I/O; Cancel or
            // Quit can never overlook a not-yet-started saved-frame load.
            try controller.beginEdit(record)
            controller.releaseLease = { [weak voice] in voice?.endFrameComment(lease) }
            editor = controller
        } catch { voice.endFrameComment(lease); store.notice = error.localizedDescription }
    }
}

/// A native menu target rechecks the actual key window and first responder at
/// dispatch, including field editors. No event monitor or text-field shortcut.
@MainActor final class PlaybackMenuCoordinator: NSObject, NSMenuItemValidation {
    enum Command: Int { case toggle = 0, back, forward, comment }
    static let shared = PlaybackMenuCoordinator()
    private let windows = NSMapTable<NSWindow, ReviewWindowRouter>(keyOptions: .weakMemory,valueOptions: .weakMemory)
    private var guards: [ObjectIdentifier: PlaybackWindowCloseGuard] = [:]
    static func isTextEditing(_ responder: NSResponder?) -> Bool {
        responder is NSTextInputClient || responder is NSTextView || responder is NSTextField
    }
    func register(_ window: NSWindow, router: ReviewWindowRouter) {
        router.window = window; windows.setObject(router,forKey: window)
        if let guarder = guards[ObjectIdentifier(window)] {
            guarder.router = router
            if window.delegate !== guarder { guarder.previous = window.delegate; window.delegate = guarder }
        } else {
            let guarder = PlaybackWindowCloseGuard(router: router, previous: window.delegate)
            guards[ObjectIdentifier(window)] = guarder; window.delegate = guarder
        }
        installMenu()
    }
    private var router: ReviewWindowRouter? { NSApp.keyWindow.flatMap { windows.object(forKey: $0) } }
    @objc func act(_ sender: NSMenuItem) { if let command = Command(rawValue: sender.tag) { router?.perform(command) } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let command = Command(rawValue: item.tag), command == .back || command == .forward,
           let interval = router?.store?.playbackPreferences.skipSeconds {
            item.title = "Skip \(command == .back ? "Backward" : "Forward") \(interval) Seconds"
        }
        return router?.enabled == true
    }
    func installMenu() {
        guard let menu = NSApp.mainMenu, menu.item(withTag: 0x434C5042) == nil else { return }
        let root = NSMenuItem(title: "Playback",action: nil,keyEquivalent: ""); root.tag = 0x434C5042
        let playback = NSMenu(title: "Playback"); root.submenu = playback
        let specs: [(String,String,NSEvent.ModifierFlags,Command)] = [
            ("Play / Pause","p",[.command,.option],.toggle),
            ("Skip Backward 5 Seconds",String(UnicodeScalar(NSLeftArrowFunctionKey)!),[.command,.option],.back),
            ("Skip Forward 5 Seconds",String(UnicodeScalar(NSRightArrowFunctionKey)!),[.command,.option],.forward),
            ("Pause and Add Frame Comment…","m",[.command,.option,.control],.comment)]
        for (title,key,modifiers,command) in specs {
            let item = NSMenuItem(title: title,action: #selector(act(_:)),keyEquivalent: key)
            item.target = self; item.tag = command.rawValue; item.keyEquivalentModifierMask = modifiers
            playback.addItem(item)
        }
        menu.insertItem(root,at: max(1,menu.numberOfItems-1))
    }
    func unregister(_ window: NSWindow, router: ReviewWindowRouter) {
        guard windows.object(forKey: window) === router else { return }
        windows.removeObject(forKey: window)
        if let guarder = guards.removeValue(forKey: ObjectIdentifier(window)), window.delegate === guarder { window.delegate = guarder.previous }
        if router.window === window { router.window = nil }
    }
    func closed(_ window: NSWindow) { windows.removeObject(forKey: window); guards.removeValue(forKey: ObjectIdentifier(window)) }
}

@MainActor private final class PlaybackWindowCloseGuard: NSObject, NSWindowDelegate {
    weak var router: ReviewWindowRouter?
    weak var previous: (any NSWindowDelegate)?
    init(router: ReviewWindowRouter, previous: (any NSWindowDelegate)?) { self.router = router; self.previous = previous }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if router?.editor != nil { NSSound.beep(); return false }
        return previous?.windowShouldClose?(sender) ?? true
    }
    func windowDidBecomeKey(_ notification: Notification) {
        previous?.windowDidBecomeKey?(notification)
        PlaybackMenuCoordinator.shared.installMenu()
    }
    func windowWillClose(_ notification: Notification) {
        previous?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow { PlaybackMenuCoordinator.shared.closed(window) }
    }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
}
struct PlaybackWindowRegistration: NSViewRepresentable {
    let router: ReviewWindowRouter
    final class Probe: NSView {
        var router: ReviewWindowRouter?
        weak var registeredWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let registeredWindow, registeredWindow !== window, let router { PlaybackMenuCoordinator.shared.unregister(registeredWindow,router: router) }
            registeredWindow = window
            if let window, let router { PlaybackMenuCoordinator.shared.register(window,router: router) }
        }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.router = router; return view }
    static func dismantleNSView(_ view: Probe,coordinator: ()) {
        if let window = view.registeredWindow, let router = view.router { PlaybackMenuCoordinator.shared.unregister(window,router: router) }
    }
    func updateNSView(_ view: Probe,context: Context) {
        view.router = router
        if let window = view.window { PlaybackMenuCoordinator.shared.register(window,router: router) }
    }
}
