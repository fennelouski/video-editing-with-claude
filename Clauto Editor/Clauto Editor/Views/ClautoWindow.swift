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
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(ClautoDesign.paper)
            window.isMovableByWindowBackground = true
        }
    }
    func makeNSView(context: Context) -> WindowView { let view = WindowView(); view.handle = handle; return view }
    func updateNSView(_ view: WindowView, context: Context) { view.handle = handle; handle.window = view.window }
}

struct ClautoWindowControls: View {
    var onRail = true
    @State private var handle = ClautoWindowHandle()
    var body: some View {
        HStack(spacing: 8) {
            control("Close window") { ClautoIcon(.close, size: 12) } action: { handle.window?.performClose(nil) }
            control("Minimize window") { Rectangle().frame(width: 10, height: 1.5).accessibilityHidden(true) } action: { handle.window?.miniaturize(nil) }
            control("Zoom window") { Rectangle().stroke(lineWidth: 1.4).frame(width: 9, height: 8).accessibilityHidden(true) } action: { handle.window?.performZoom(nil) }
        }.background(ClautoWindowReader(handle: handle).frame(width: 0, height: 0))
    }
    private func control<Glyph: View>(_ label: String, @ViewBuilder glyph: () -> Glyph, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph().frame(width: 24, height: 24).foregroundStyle(onRail ? ClautoDesign.paper : ClautoDesign.ink).background(onRail ? ClautoDesign.ink : ClautoDesign.soft, in: CutCorner(cut: 4)) }
            .buttonStyle(ClautoInlineButtonStyle(onRail: onRail)).accessibilityLabel(label).help(label)
    }
}
