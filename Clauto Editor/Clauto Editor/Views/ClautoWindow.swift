import SwiftUI
import AppKit

@MainActor final class ClautoWindowHandle { weak var window: NSWindow? }

private struct ClautoWindowReader: NSViewRepresentable {
    let handle: ClautoWindowHandle
    final class WindowView: NSView {
        var handle: ClautoWindowHandle?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); handle?.window = window
            guard let window else { return }
            // Only our own window. Native close/minimize/zoom behavior remains
            // behind the authored controls; menus and keyboard commands still work.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = ClautoThemeStore.shared.selected != .standard }
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            ClautoThemeStore.shared.applyNativeAppearance(to: window)
            window.backgroundColor = ClautoThemeStore.shared.selected == .standard ? .windowBackgroundColor:NSColor(ClautoDesign.paper)
            window.isMovableByWindowBackground = true
        }
    }
    func makeNSView(context: Context) -> WindowView { let view = WindowView(); view.handle = handle; return view }
    func updateNSView(_ view: WindowView, context: Context) {
        view.handle = handle; handle.window = view.window
        guard let window = view.window else { return }
        for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] { window.standardWindowButton(kind)?.isHidden = ClautoThemeStore.shared.selected != .standard }
        ClautoThemeStore.shared.applyNativeAppearance(to: window)
        window.backgroundColor = ClautoThemeStore.shared.selected == .standard ? .windowBackgroundColor:NSColor(ClautoDesign.paper)
    }
}

struct ClautoWindowControls: View {
    var onRail = true
    @State private var handle = ClautoWindowHandle()
    var body: some View {
        Group {
        if ClautoThemeStore.shared.selected == .standard { Color.clear.frame(width: 96,height: 28).allowsHitTesting(false) }
        else { HStack(spacing: 6) {
            control("Close window") { ClautoIcon(.close, size: 11) } action: {
                // Keep the native close path and its delegate vetoes.
                guard let window=handle.window else { return }
                window.performClose(nil)
                #if DEBUG
                if ProcessInfo.processInfo.environment["CLAUTO_SOUND_SILENT_QA"]=="1" { NSLog("Sound QA native close returned: visible=%d",window.isVisible ? 1:0) }
                #endif
            }
            control("Minimize window") { Rectangle().frame(width: 9, height: 1.25).accessibilityHidden(true) } action: { handle.window?.miniaturize(nil) }
            control("Zoom window") { Rectangle().stroke(lineWidth: 1.25).frame(width: 8, height: 7).accessibilityHidden(true) } action: { handle.window?.performZoom(nil) }
        } }
        }.background(ClautoWindowReader(handle: handle).frame(width: 0, height: 0))
    }
    private func control<Glyph: View>(_ label: String, @ViewBuilder glyph: () -> Glyph, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph().frame(width: 22, height: 22)
                .foregroundStyle(onRail ? ClautoDesign.railText : ClautoDesign.ink)
                .background(onRail ? ClautoDesign.railText.opacity(0.08) : ClautoDesign.soft,in: RoundedRectangle(cornerRadius: 5,style: .continuous))
                .padding(3).contentShape(Rectangle())
        }
            .buttonStyle(ClautoInlineButtonStyle(onRail: onRail)).accessibilityLabel(label).clautoHelp(label)
    }
}
