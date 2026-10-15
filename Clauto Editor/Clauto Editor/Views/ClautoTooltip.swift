import SwiftUI
import AppKit

/// One non-key panel for the app. Pending hover generations cannot resurrect
/// stale tips, and the text remains selectable without stealing key focus.
@MainActor final class ClautoTooltipCenter {
    static let shared = ClautoTooltipCenter()
    private var panel: NSPanel?
    private var owner: UUID?
    private var message = ""
    private var pending: Task<Void,Never>?
    private var flagsMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private init() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if event.modifierFlags.contains(.option) { self?.reveal() }; return event
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,object: nil,queue: .main) { [weak self] _ in
            let center = self; Task { @MainActor in center?.hide() }
        }
    }
    func enter(_ id: UUID,text: String,immediate: Bool = false) {
        hide(); owner = id; message = text
        if immediate || NSEvent.modifierFlags.contains(.option) { reveal(); return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, self?.owner == id else { return }; self?.reveal()
        }
    }
    func leave(_ id: UUID) {
        guard owner == id else { return }; pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self?.owner == id else { return }
            if let frame = self?.panel?.frame, frame.contains(NSEvent.mouseLocation) { return }
            self?.hide()
        }
    }
    func hide() { pending?.cancel(); pending = nil; owner = nil; panel?.orderOut(nil) }
    private func reveal() {
        guard owner != nil else { return }
        pending?.cancel(); pending = nil
        let panel = panel ?? NSPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        self.panel = panel; panel.isReleasedWhenClosed = false; panel.level = .popUpMenu; panel.hidesOnDeactivate = true
        panel.hasShadow = true; panel.backgroundColor = .windowBackgroundColor
        let label = NSTextField(wrappingLabelWithString: message)
        label.isSelectable = true; label.font = .systemFont(ofSize: 12); label.textColor = .labelColor
        let width = min(380,max(140,CGFloat(message.count)*6))
        let height = ceil((message as NSString).boundingRect(with: NSSize(width: width,height: 2000),options: [.usesLineFragmentOrigin],attributes: [.font:NSFont.systemFont(ofSize: 12)]).height)+4
        label.frame = NSRect(x: 10,y: 8,width: width,height: height)
        let content = TooltipContent(frame: NSRect(x: 0,y: 0,width: width+20,height: height+16))
        content.addSubview(label); content.left = { [weak self] in self?.hide() }
        panel.contentView = content
        let point = NSEvent.mouseLocation, screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var frame = NSRect(x: point.x+12,y: point.y-74,width: content.frame.width,height: content.frame.height)
        if let bounds = screen?.visibleFrame {
            frame.origin.x = max(bounds.minX,min(frame.minX,bounds.maxX-frame.width)); frame.origin.y = max(bounds.minY,min(frame.minY,bounds.maxY-frame.height))
        }
        panel.setFrame(frame,display: true); panel.orderFront(nil)
    }
}
@MainActor private final class TooltipContent: NSView {
    var left: (() -> Void)?
    override func updateTrackingAreas() { for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect: bounds,options: [.activeAlways,.mouseEnteredAndExited],owner: self)); super.updateTrackingAreas() }
    override func mouseExited(with event: NSEvent) { left?() }
}
private struct ClautoTooltipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()
    @Environment(\.isFocused) private var focused
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering { ClautoTooltipCenter.shared.enter(id,text: text) } else { ClautoTooltipCenter.shared.leave(id) }
        }.onChange(of: focused) { if focused { ClautoTooltipCenter.shared.enter(id,text: text,immediate: true) } else { ClautoTooltipCenter.shared.leave(id) } }
            .onDisappear { ClautoTooltipCenter.shared.leave(id) }
    }
}
extension View { func clautoHelp(_ text: String) -> some View { modifier(ClautoTooltipModifier(text: text)) } }
