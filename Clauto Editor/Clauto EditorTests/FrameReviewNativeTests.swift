// These app-host tests exercise the actual AppKit responders/menu targets.
// SwiftPM covers the same core contracts without opening graphical windows.
#if !canImport(ClautoCore)
import AppKit
import SwiftUI
import Testing
@testable import Clauto_Editor

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLAUTO_NATIVE_WINDOW_ACCEPTANCE"] == "1", "Requires an active graphical test host; inactive Xcode hosts cannot receive key-window routing")) struct FrameReviewNativeTests {
    private func focus(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<40 {
            if NSApp.keyWindow === window { return }
            try await Task.sleep(for: .milliseconds(25))
            window.makeKey()
        }
        Issue.record("Synthetic key window unavailable: active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), canKey=\(window.canBecomeKey), visible=\(window.isVisible), isKey=\(window.isKeyWindow), modal=\(String(describing: NSApp.modalWindow)), key=\(String(describing: NSApp.keyWindow))")
    }
    @Test func keyWindowTextEditorsModalsSelectionAndDispatchAreScoped() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let suite = "clauto-native-test-"+UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorStore(defaults: defaults), router = ReviewWindowRouter(), other = ReviewWindowRouter()
        router.store = store; other.store = store
        let driver = FakeReviewDriver(), second = FakeReviewDriver()
        let endpoint = ReviewPlaybackEndpoint(id: UUID(),project: f.project,target: f.target,driver: driver)
        router.register(endpoint)
        let late = ReviewPlaybackEndpoint(id: UUID(),project: f.project,target: f.target,driver: second)
        router.register(late); #expect(router.selectedID == endpoint.id)
        let window = NSWindow(contentRect: CGRect(x: 60,y: 60,width: 660,height: 460),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        let another = NSWindow(contentRect: CGRect(x: 80,y: 80,width: 660,height: 460),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; another.isReleasedWhenClosed = false
        defer { window.close(); another.close() }
        PlaybackMenuCoordinator.shared.register(window,router: router)
        PlaybackMenuCoordinator.shared.register(another,router: other)
        try await focus(window); window.makeFirstResponder(window.contentView)
        #expect(NSApp.keyWindow === window && router.enabled)
        let item = NSMenuItem(title: "Test",action: nil,keyEquivalent: "p"); item.tag = PlaybackMenuCoordinator.Command.toggle.rawValue
        #expect(PlaybackMenuCoordinator.shared.validateMenuItem(item))
        PlaybackMenuCoordinator.shared.act(item); #expect(driver.log == ["toggle"])
        // Native field editor, multiline editor, and search field all refuse
        // even a direct dispatch after a previously successful validation.
        let field = NSTextField(frame: CGRect(x: 20,y: 20,width: 200,height: 24))
        window.contentView?.addSubview(field); window.makeFirstResponder(field)
        #expect(PlaybackMenuCoordinator.isTextEditing(window.firstResponder))
        #expect(!router.enabled); PlaybackMenuCoordinator.shared.act(item); #expect(driver.log == ["toggle"])
        let text = NSTextView(frame: CGRect(x: 20,y: 50,width: 200,height: 80)); window.contentView?.addSubview(text); window.makeFirstResponder(text)
        #expect(!router.enabled); PlaybackMenuCoordinator.shared.act(item); #expect(driver.log == ["toggle"])
        let search = NSSearchField(frame: CGRect(x: 20,y: 150,width: 200,height: 24)); window.contentView?.addSubview(search); window.makeFirstResponder(search)
        #expect(!router.enabled)
        window.makeFirstResponder(window.contentView)
        let modal = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 220,height: 100),styleMask: [.titled],backing: .buffered,defer: false)
        modal.isReleasedWhenClosed = false
        window.beginSheet(modal,completionHandler: { _ in })
        #expect(!router.enabled); PlaybackMenuCoordinator.shared.act(item); #expect(driver.log == ["toggle"])
        window.endSheet(modal); modal.orderOut(nil); try await focus(window)
        router.select(late.id); PlaybackMenuCoordinator.shared.act(item); #expect(second.log == ["toggle"])
        router.unregister(endpoint.id); #expect(router.selectedID == late.id)
        try await focus(another); #expect(!router.enabled)
        PlaybackMenuCoordinator.shared.act(item); #expect(second.log == ["toggle"])
        try await focus(window); driver.seeking = true; router.select(late.id); second.seeking = true
        #expect(!router.enabled); second.seeking = false
        router.unregister(late.id); #expect(!router.enabled && router.selectedID == nil)
        // Settings/another window has no fallback to this last selected player.
        #expect(!other.enabled)
    }
    @Test func nativeMenusInstallOnceAndAnnotationUndoDoesNotStealTextUndo() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        PlaybackMenuCoordinator.shared.installMenu(); PlaybackMenuCoordinator.shared.installMenu()
        let menus = NSApp.mainMenu?.items.filter { $0.tag == 0x434C5042 } ?? []
        #expect(menus.count == 1)
        let items = try #require(menus.first?.submenu?.items)
        #expect(items.count == 4)
        #expect(Set(items.map { "\($0.keyEquivalent):\($0.keyEquivalentModifierMask.rawValue)" }).count == 4)
        #expect(items[3].keyEquivalentModifierMask == [.command,.option,.control])
        let frozen = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let draft = FrameCommentDraft(request: frozen.request,frame: frozen)
        try draft.add(.init(x: 0.2,y: 0.2,width: 0.3,height: 0.3),kind: .ellipse)
        let window = NSWindow(contentRect: CGRect(x: 60,y: 60,width: 660,height: 460),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let canvas = AnnotationImageView(frame: CGRect(x: 0,y: 0,width: 500,height: 280)); canvas.draft = draft; canvas.image = NSImage(data: frozen.png)
        window.contentView?.addSubview(canvas)
        let text = NSTextView(frame: CGRect(x: 0,y: 300,width: 400,height: 100)); text.allowsUndo = true; window.contentView?.addSubview(text)
        try await focus(window); window.makeFirstResponder(text)
        text.insertText("Native text undo",replacementRange: NSRange(location: NSNotFound,length: 0))
        #expect(NSApp.sendAction(#selector(AnnotationImageView.undo(_:)),to: nil,from: nil)); #expect(text.string.isEmpty)
        #expect(draft.history.shapes.count == 1)
        window.makeFirstResponder(canvas)
        #expect(NSApp.sendAction(#selector(AnnotationImageView.undo(_:)),to: nil,from: nil)); #expect(draft.history.shapes.isEmpty)
        #expect(NSApp.sendAction(#selector(AnnotationImageView.redo(_:)),to: nil,from: nil)); #expect(draft.history.shapes.count == 1)
        let router = ReviewWindowRouter(); router.editor = FrameCommentController(project: f.project)
        PlaybackMenuCoordinator.shared.register(window,router: router)
        #expect(window.delegate?.windowShouldClose?(window) == false)
        router.editor = nil
        #expect(window.delegate?.windowShouldClose?(window) != false)
    }
}
@MainActor @Suite(.serialized) struct FrameReviewAppKitStructureTests {
    @Test func nativeMenuChordsAndReplacementRouterCloseGuardAreConsistent() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        PlaybackMenuCoordinator.shared.installMenu(); PlaybackMenuCoordinator.shared.installMenu()
        let roots = NSApp.mainMenu?.items.filter { $0.tag == 0x434C5042 } ?? []
        #expect(roots.count == 1)
        let commands = try #require(roots.first?.submenu?.items)
        #expect(commands.count == 4 && commands[3].keyEquivalentModifierMask == [.command,.option,.control])
        func equivalents(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { item in
                var values = item.keyEquivalent.isEmpty ? [] : ["\(item.keyEquivalent):\(item.keyEquivalentModifierMask.rawValue)"]
                if let submenu = item.submenu { values += equivalents(submenu) }; return values
            }
        }
        let all = equivalents(try #require(NSApp.mainMenu))
        for command in commands { #expect(all.filter { $0 == "\(command.keyEquivalent):\(command.keyEquivalentModifierMask.rawValue)" }.count == 1) }
        let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 600,height: 400),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let old = ReviewWindowRouter(), replacement = ReviewWindowRouter()
        PlaybackMenuCoordinator.shared.register(window,router: old)
        replacement.editor = FrameCommentController(project: f.project)
        PlaybackMenuCoordinator.shared.register(window,router: replacement)
        #expect(window.delegate?.windowShouldClose?(window) == false)
        PlaybackMenuCoordinator.shared.unregister(window,router: old)
        old.dismissEditor(); #expect(window.delegate?.windowShouldClose?(window) == false)
        replacement.dismissEditor(); #expect(window.delegate?.windowShouldClose?(window) != false)
    }
    @Test func realAppKitFieldEditorsAndCanvasRemainDistinctResponders() {
        let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 600,height: 400),styleMask: [.titled],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        for view in [NSTextField(frame: .zero),NSSearchField(frame: .zero),NSTextView(frame: .zero)] as [NSView] {
            window.contentView?.addSubview(view)
            #expect(window.makeFirstResponder(view))
            #expect(PlaybackMenuCoordinator.isTextEditing(window.firstResponder))
        }
        let canvas = ClautoVideoCanvas(frame: .zero); canvas.onSpace = {}
        window.contentView?.addSubview(canvas); #expect(window.makeFirstResponder(canvas))
        #expect(!PlaybackMenuCoordinator.isTextEditing(window.firstResponder))
    }
    @Test func actualFrozenFrameEditorRendersSyntheticPNGAndMarks() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let controller = FrameCommentController(project: f.project)
        try controller.begin(f.request())
        for _ in 0..<200 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(20)) }
        let draft = try #require(controller.draft), frame = try #require(draft.frame)
        draft.text = "Keep this detail visible. Synthetic frame review only."
        try draft.add(.init(x: 0.2,y: 0.2,width: 0.3,height: 0.3),kind: .ellipse)
        let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 900,height: 850),styleMask: [.titled],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        defer { _ = controller.cancel(); window.close() }
        let host = NSHostingView(rootView: FrameCommentEditor(controller: controller,close: {}))
        window.contentView = host; host.frame = CGRect(x: 0,y: 0,width: 900,height: 850)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds,to: bitmap)
        let png = try #require(bitmap.representation(using: .png,properties: [:]))
        #expect(png.count > 10_000 && frame.width == 160)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: repo.appendingPathComponent(".artifacts/frame-review-synthetic-editor.png"))
    }
}
#endif
