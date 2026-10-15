import SwiftUI
import AppKit
import Observation

/// Per-window selection. A comparison player can only take ownership through
/// its own selection button or canvas; late-loading players never steal it.
@MainActor @Observable final class ReviewWindowRouter {
    let id = UUID()
    var inlineEndpointID: UUID?
    var intendedVersionID: UUID?
    var returnVersionID: UUID?
    private(set) var endpoints: [UUID: ReviewPlaybackEndpoint] = [:]
    private(set) var selectedID: UUID?
    var editor: FrameCommentController?
    var tab = "Brief"
    var paletteVisible = false
    var showTimecode = false
    var onWorkspaceCommand: ((EditorCommand) -> Void)?
    private var paletteEndpoint: UUID?
    private var paletteProject: UUID?
    private var pendingCommand: EditorCommand?
    @ObservationIgnored private weak var paletteOriginWindow: NSWindow?
    var ownsSheetContext: Bool { paletteVisible || pendingCommand != nil || showTimecode || editor != nil }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var store: EditorStore?
    func register(_ endpoint: ReviewPlaybackEndpoint) {
        endpoints[endpoint.id] = endpoint
        if selectedID == nil && (intendedVersionID == nil || intendedVersionID == endpoint.target.versionID) { selectedID = endpoint.id }
    }
    func unregister(_ id: UUID) {
        if let endpoint = endpoints[id], let editor, editor.preparing, editor.draft?.request.target == endpoint.target {
            _ = editor.cancel(); dismissEditor()
        }
        endpoints.removeValue(forKey: id)
        if selectedID == id { selectedID = nil }
    }
    func select(_ id: UUID) { if let endpoint = endpoints[id] { selectedID = id; intendedVersionID = endpoint.target.versionID } }
    var selected: ReviewPlaybackEndpoint? { selectedID.flatMap { endpoints[$0] } }
    var enabled: Bool { canPerform(.toggle) }
    func canPerform(_ command: EditorCommand, fromPalette: Bool = false) -> Bool {
        guard let key = NSApp.keyWindow, PlaybackMenuCoordinator.shared.owns(key,router: self), let store else { return false }
        if key.attachedSheet != nil || window?.attachedSheet != nil || NSApp.modalWindow != nil || editor != nil || paletteVisible || showTimecode { return false }
        if [.comment,.timecode,.palette,.brief,.files,.transcript,.review].contains(command) && window == nil { return false }
        if command.needsPlayer {
            if !fromPalette && PlaybackMenuCoordinator.isTextEditing(key.firstResponder) { return false }
            return selected?.ready == true
        }
        if command == .palette { return true }
        return store.selected != nil
    }
    func choosePaletteCommand(_ command: EditorCommand) { pendingCommand = command; paletteVisible = false }
    func finishPalette() {
        guard let command = pendingCommand else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.pendingCommand = nil }
            // SwiftUI's dismissal callback can precede AppKit sheet/key restoration.
            for _ in 0..<20 {
                if self.window?.attachedSheet == nil { break }; try? await Task.sleep(for: .milliseconds(10))
            }
            guard self.store?.selectedID == self.paletteProject,
                  !command.needsPlayer || self.selectedID == self.paletteEndpoint,
                  let origin = self.paletteOriginWindow, origin.isVisible,
                  PlaybackMenuCoordinator.shared.owns(origin,router: self) else { self.store?.notice = "The selected player changed. Open Commands again."; return }
            origin.makeKeyAndOrderFront(nil)
            self.perform(command, explicitControl: true)
        }
    }
    func perform(_ command: EditorCommand, explicitControl: Bool = false) {
        guard canPerform(command,fromPalette: explicitControl), let store else { return }
        if command == .palette {
            paletteEndpoint = selectedID; paletteProject = store.selectedID; paletteOriginWindow = NSApp.keyWindow; paletteVisible = true; return
        }
        switch command {
        case .brief: tab = "Brief"
        case .files: tab = "Files"
        case .transcript: tab = "Transcript"
        case .review: tab = "Cut"
        case .toggle: selected?.driver.toggle()
        case .back: selected?.skip(-store.playbackPreferences.skipSeconds)
        case .forward: selected?.skip(store.playbackPreferences.skipSeconds)
        case .comment: if let selected { beginComment(selected) }
        case .stop: selected?.driver.pause()
        case .reverse: (selected?.driver as? ReviewPlaybackControl)?.shuttle(-1)
        case .play: (selected?.driver as? ReviewPlaybackControl)?.shuttle(1)
        case .previousFrame: selected?.step(-1)
        case .nextFrame: selected?.step(1)
        case .timecode: showTimecode = true
        case .detach,.fullScreen,.pictureInPicture:
            guard let selected, let session = store.reviewPlayers[selected.id] else { return }
            if command == .detach { session.presentation.toggleDetach() }
            if command == .fullScreen { session.presentation.toggleFullScreen() }
            if command == .pictureInPicture { session.presentation.showNativeControls() }
        default: onWorkspaceCommand?(command)
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
    func recoverDictation(_ record: RegionDictationRecord,project: Project) {
        guard editor == nil, let store, let voice = store.voiceReview(for: project) else { return }
        let controller = store.frameComment(for: project), lease = UUID()
        guard !controller.hasPendingWork, voice.beginFrameComment(lease) else { store.notice = "Finish or close the open frame first."; return }
        selected?.driver.pause()
        do {
            try controller.beginRecoverDictation(record.id)
            controller.releaseLease = { [weak voice] in voice?.endFrameComment(lease) }
            editor = controller
        } catch { voice.endFrameComment(lease); store.notice = error.localizedDescription }
    }
    func restoreInlineSelection() {
        guard let id = inlineEndpointID else { return }
        if let session = store?.reviewPlayers[id] { intendedVersionID = session.version.id }
        select(id)
    }
    func dismissEditor() { editor = nil }
    func edit(_ record: SavedFrameComment, project: Project) {
        guard editor == nil, let store, let voice = store.voiceReview(for: project) else { return }
        let controller = store.frameComment(for: project), lease = UUID()
        guard !controller.hasPendingWork, voice.beginFrameComment(lease) else { store.notice = "Finish or close the open frame or candidate review first."; return }
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
    typealias Command = EditorCommand
    static let shared = PlaybackMenuCoordinator()
    private let windows = NSMapTable<NSWindow, ReviewWindowRouter>(keyOptions: .weakMemory,valueOptions: .weakMemory)
    private var guards: [ObjectIdentifier: PlaybackWindowCloseGuard] = [:]
    static func isTextEditing(_ responder: NSResponder?) -> Bool {
        responder is NSTextInputClient || responder is NSTextView || responder is NSTextField
    }
    func register(_ window: NSWindow, router: ReviewWindowRouter, primary: Bool = true) {
        if primary { router.window = window }; windows.setObject(router,forKey: window)
        if let guarder = guards[ObjectIdentifier(window)] {
            guarder.router = router
            if window.delegate !== guarder { guarder.previous = window.delegate; window.delegate = guarder }
        } else {
            let guarder = PlaybackWindowCloseGuard(router: router, previous: window.delegate)
            guards[ObjectIdentifier(window)] = guarder; window.delegate = guarder
        }
        installMenu()
    }
    func owns(_ window: NSWindow,router: ReviewWindowRouter) -> Bool { windows.object(forKey: window) === router }
    private var router: ReviewWindowRouter? { NSApp.keyWindow.flatMap { windows.object(forKey: $0) } }
    @objc func act(_ sender: NSMenuItem) { if let command = Command(rawValue: sender.tag) { router?.perform(command) } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let command = Command(rawValue: item.tag), command == .back || command == .forward,
           let interval = router?.store?.playbackPreferences.skipSeconds {
            item.title = "Skip \(command == .back ? "Backward" : "Forward") \(interval) Seconds"
        }
        return Command(rawValue: item.tag).map { router?.canPerform($0) == true } ?? false
    }
    func installMenu() {
        guard let menu = NSApp.mainMenu, menu.item(withTag: 0x434C5042) == nil else { return }
        let root = NSMenuItem(title: "Playback",action: nil,keyEquivalent: ""); root.tag = 0x434C5042
        let playback = NSMenu(title: "Playback"); root.submenu = playback
        for command in Command.allCases {
            let shortcut: (String,NSEvent.ModifierFlags)
            switch command {
            case .toggle: shortcut = ("p",[.command,.option])
            case .back: shortcut = (String(UnicodeScalar(NSLeftArrowFunctionKey)!),[.command,.option])
            case .forward: shortcut = (String(UnicodeScalar(NSRightArrowFunctionKey)!),[.command,.option])
            case .comment: shortcut = ("m",[.command,.option,.control])
            case .palette: shortcut = ("p",[.command,.shift])
            case .timecode: shortcut = ("t",[.command,.option])
            case .brief,.files,.transcript,.review: shortcut = (String(command.rawValue-Command.brief.rawValue+1),[.command,.option])
            case .focusAssets,.focusVideo,.focusFeedback: shortcut = (String(command.rawValue-Command.focusAssets.rawValue+1),[.command,.option,.control])
            default: shortcut = ("",[])
            }
            let item = NSMenuItem(title: command.title,action: #selector(act(_:)),keyEquivalent: shortcut.0)
            item.target = self; item.tag = command.rawValue; item.keyEquivalentModifierMask = shortcut.1
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
    func closed(_ window: NSWindow) {
        if let router = windows.object(forKey: window), router.window === window {
            router.window = nil
            for session in router.store?.reviewPlayers.values.filter({ $0.ownerID == router.id }) ?? [] { session.ownerDidClose() }
        }
        windows.removeObject(forKey: window); guards.removeValue(forKey: ObjectIdentifier(window)) }
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
        if let window = notification.object as? NSWindow, window === router?.window, router?.ownsSheetContext == false { router?.restoreInlineSelection() }
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
