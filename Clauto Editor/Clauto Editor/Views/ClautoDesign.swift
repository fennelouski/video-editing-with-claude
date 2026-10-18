import SwiftUI
import AppKit
import CoreText

@MainActor enum ClautoDesign {
    /// Native attributed control titles can retain a previously resolved dynamic
    /// NSColor. Re-resolve semantic roles when the observed system scheme changes.
    private static func systemColor(_ color: NSColor) -> Color {
        _ = ClautoThemeStore.shared.systemAppearanceRevision
        var resolved = color
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return Color(nsColor: resolved)
    }
    static var ink: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.labelColor) }; return ClautoThemeStore.shared.palette.ink.color }
    static var rail: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.underPageBackgroundColor) }; return ClautoThemeStore.shared.palette.sidebar.color }
    static var railText: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.labelColor) }; return ClautoThemeStore.shared.palette.sidebarInk.color }
    static var paper: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.windowBackgroundColor) }; return ClautoThemeStore.shared.palette.background.color }
    static var sheet: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.textBackgroundColor) }; return ClautoThemeStore.shared.palette.surface.color }
    static var soft: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.controlBackgroundColor) }; return ClautoThemeStore.shared.palette.subtle.color }
    static var citron: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.controlAccentColor) }; return ClautoThemeStore.shared.palette.accent.color }
    static var onAccent: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.alternateSelectedControlTextColor) }; return ClautoThemeStore.shared.palette.accentInk.color }
    static var quiet: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.secondaryLabelColor) }; return ClautoThemeStore.shared.palette.muted.color }
    static var rule: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.separatorColor) }; return ClautoThemeStore.shared.palette.border.color }
    static var ember: Color { if ClautoThemeStore.shared.selected == .standard { return systemColor(.systemRed) }; return ClautoThemeStore.shared.palette.error.color }
    static func type(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        switch ClautoThemeStore.shared.palette.geometry.type {
        case .system: .system(size: size,weight: weight)
        case .mono: .system(size: size,weight: weight,design: .monospaced)
        case .serif: .system(size: size,weight: weight,design: .serif)
        case .humanist: .custom("WorkSans-Regular",size: size).weight(weight)
        }
    }
    static var body: Font { type() }
    static var caption: Font { type(12) }
    static var heading: Font { type(24, weight: .semibold) }
    static func nativeFont(_ size: CGFloat) -> NSFont {
        switch ClautoThemeStore.shared.palette.geometry.type {
        case .system: .systemFont(ofSize: size)
        case .mono: .monospacedSystemFont(ofSize: size,weight: .regular)
        case .serif: NSFont(descriptor: NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor,size: size) ?? .systemFont(ofSize: size)
        case .humanist: NSFont(name: "WorkSans-Regular",size: size) ?? .systemFont(ofSize: size)
        }
    }
}

@MainActor enum ClautoFonts {
    private static var registered = false
    /// Registers the existing OFL font only in this app process.
    static func register() {
        guard !registered else { return }
        guard let url = Bundle.main.url(forResource: "ClautoWorkSans", withExtension: "ttf") else {
            assertionFailure("The bundled Clauto Work Sans font is missing."); return
        }
        var error: Unmanaged<CFError>?
        registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            || NSFont(name: "WorkSans-Regular", size: 14) != nil
        assert(registered, "The bundled Clauto Work Sans font could not be registered.")
    }
}

enum ClautoButtonKind { case primary, secondary, quiet, danger }
struct ClautoButtonStyle: ButtonStyle {
    var kind: ClautoButtonKind = .secondary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClautoDesign.type(13, weight: .semibold))
            .foregroundStyle(enabled ? (kind == .danger ? ClautoDesign.ember : kind == .primary && enabled && !configuration.isPressed && !hovering ? ClautoDesign.onAccent : ClautoDesign.ink) : ClautoDesign.quiet)
            .padding(.horizontal, kind == .quiet ? 8 : ClautoThemeStore.shared.palette.geometry.inset+3).padding(.vertical, ClautoThemeStore.shared.palette.spacing*0.6)
            .background(background(pressed: configuration.isPressed), in: ClautoThemedShape(palette: ClautoThemeStore.shared.palette))
            .overlay(ClautoThemedShape(palette: ClautoThemeStore.shared.palette).stroke(focused ? ClautoDesign.ink : kind == .quiet ? .clear : ClautoDesign.rule, lineWidth: focused ? ClautoThemeStore.shared.palette.geometry.focusStroke : ClautoThemeStore.shared.palette.geometry.stroke))
            .contentShape(Rectangle()).focusEffectDisabled()
            .onHover { hovering = $0 }
    }
    private func background(pressed: Bool) -> Color {
        if !enabled { return kind == .quiet ? .clear : ClautoDesign.soft }
        if pressed { return ClautoDesign.soft }
        if kind == .primary { return hovering ? ClautoDesign.soft : ClautoDesign.citron }
        return hovering ? ClautoDesign.soft : kind == .quiet ? .clear : ClautoDesign.sheet
    }
}

/// Authored feedback for rows, tabs, disclosure triggers, and checkbox controls.
struct ClautoInlineButtonStyle: ButtonStyle {
    var onRail = false
    var selected = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(background(pressed: configuration.isPressed))
            .overlay(Rectangle().stroke(focused ? (onRail ? ClautoDesign.citron : ClautoDesign.ink) : .clear, lineWidth: ClautoThemeStore.shared.palette.geometry.focusStroke))
            .contentShape(Rectangle()).focusEffectDisabled()
            .opacity(enabled ? 1 : 0.65)
            .onHover { hovering = $0 }
    }
    private func background(pressed: Bool) -> Color {
        if selected { return onRail ? ClautoDesign.citron : ClautoDesign.soft }
        guard enabled, hovering || pressed else { return .clear }
        return onRail ? ClautoDesign.railText.opacity(0.08) : ClautoDesign.soft
    }
}

struct CutCorner: Shape {
    var cut: CGFloat = 6
    func path(in r: CGRect) -> Path {
        let inset = min(max(0, cut), min(r.width, r.height) / 2)
        return Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX-inset, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY+inset)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        }
    }
}

/// Semantic geometry is shared by controls, fields, rails and icon badges.
struct ClautoThemedShape: Shape {
    let style: ClautoThemePalette.ShapeStyle
    let corner: CGFloat
    init(palette: ClautoThemePalette) { style = palette.geometry.shape;corner = palette.corner }
    func path(in r: CGRect) -> Path {
        switch style {
        case .square: return Rectangle().path(in: r)
        case .rounded: return RoundedRectangle(cornerRadius: corner).path(in: r)
        case .capsule: return Capsule().path(in: r)
        case .cut: return CutCorner(cut: corner).path(in: r)
        case .chamfer:
            let c = min(max(3,corner),min(r.width,r.height)/3)
            return Path { p in
                p.move(to: .init(x: r.minX+c,y: r.minY));p.addLine(to: .init(x: r.maxX-c,y: r.minY))
                p.addLine(to: .init(x: r.maxX,y: r.minY+c));p.addLine(to: .init(x: r.maxX,y: r.maxY-c))
                p.addLine(to: .init(x: r.maxX-c,y: r.maxY));p.addLine(to: .init(x: r.minX+c,y: r.maxY))
                p.addLine(to: .init(x: r.minX,y: r.maxY-c));p.addLine(to: .init(x: r.minX,y: r.minY+c));p.closeSubpath()
            }
        }
    }
}

struct ClautoAction: View {
    let title: String
    var icon: ClautoIconName? = nil
    var kind: ClautoButtonKind = .secondary
    var action: () -> Void
    init(_ title: String, icon: ClautoIconName? = nil, kind: ClautoButtonKind = .secondary, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.kind = kind; self.action = action
    }
    var body: some View {
        Group {
            if ClautoThemeStore.shared.selected == .standard {
                Button(action: action) { Label { Text(title) } icon: { if let icon { ClautoIcon(icon, size: 16) } } }
                    .buttonStyle(.bordered).tint(kind == .primary ? .accentColor : nil)
            } else {
                Button(action: action) { HStack(spacing: 7) { if let icon { ClautoIcon(icon, size: 16) }; Text(title) } }
                    .buttonStyle(ClautoButtonStyle(kind: kind))
            }
        }.accessibilityLabel(title)
    }
}

struct ClautoRule: View {
    var body: some View { Rectangle().fill(ClautoDesign.rule).frame(height: ClautoThemeStore.shared.palette.geometry.stroke).accessibilityHidden(true) }
}

struct ClautoSection<Content: View>: View {
    var title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: ClautoThemeStore.shared.palette.spacing) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(ClautoDesign.type(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if let detail { Text(detail).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClautoField: View {
    var label: String
    @Binding var text: String
    var placeholder = ""
    var axis: Axis = .horizontal
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty { Text(label).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
            TextField(label, text: $text, prompt: Text(placeholder).foregroundStyle(ClautoDesign.quiet),axis: axis)
                .textFieldStyle(.plain).font(ClautoDesign.body).foregroundStyle(enabled ? ClautoDesign.ink : ClautoDesign.quiet)
                .tint(ClautoDesign.ink).padding(ClautoThemeStore.shared.palette.geometry.inset).background(enabled ? ClautoDesign.sheet : ClautoDesign.soft,in: ClautoThemedShape(palette: ClautoThemeStore.shared.palette))
                .overlay(ClautoThemedShape(palette: ClautoThemeStore.shared.palette).stroke(focused ? ClautoDesign.ink : ClautoDesign.rule, lineWidth: focused ? ClautoThemeStore.shared.palette.geometry.focusStroke : ClautoThemeStore.shared.palette.geometry.stroke))
                .focused($focused).focusEffectDisabled().accessibilityLabel(label.isEmpty ? placeholder : label)
        }
    }
}

struct ClautoNumberField: View {
    var label: String
    @Binding var value: Double
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            TextField(label, value: $value, format: .number).textFieldStyle(.plain).font(ClautoDesign.body.monospacedDigit())
                .tint(ClautoDesign.ink).padding(ClautoThemeStore.shared.palette.geometry.inset).background(enabled ? ClautoDesign.sheet : ClautoDesign.soft,in: ClautoThemedShape(palette: ClautoThemeStore.shared.palette))
                .overlay(ClautoThemedShape(palette: ClautoThemeStore.shared.palette).stroke(focused ? ClautoDesign.ink : ClautoDesign.rule, lineWidth: focused ? ClautoThemeStore.shared.palette.geometry.focusStroke : ClautoThemeStore.shared.palette.geometry.stroke))
                .focused($focused).focusEffectDisabled().accessibilityLabel(label)
        }
    }
}

/// NSTextView supplies editing; SwiftUI owns text and the visible focus treatment.
struct ClautoTextArea: View {
    @Binding var text: String
    var label: String
    @State private var focused = false
    var body: some View {
        ClautoNativeTextArea(text: $text, label: label, focused: $focused)
            .overlay(Rectangle().stroke(focused ? ClautoDesign.ink : ClautoDesign.rule, lineWidth: focused ? ClautoThemeStore.shared.palette.geometry.focusStroke : ClautoThemeStore.shared.palette.geometry.stroke))
    }
}
private struct ClautoNativeTextArea: NSViewRepresentable {
    @Binding var text: String
    var label: String
    @Binding var focused: Bool
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.verticalScroller = ClautoScroller()
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(ClautoDesign.sheet)
        let view = ClautoNativeTextView(); view.delegate = context.coordinator; view.isRichText = false; view.allowsUndo = true
        view.font = ClautoDesign.nativeFont(15)
        view.textColor = NSColor(ClautoDesign.ink); view.backgroundColor = NSColor(ClautoDesign.sheet)
        view.insertionPointColor = NSColor(ClautoDesign.ink)
        view.selectedTextAttributes = [.backgroundColor: NSColor(ClautoDesign.citron), .foregroundColor: NSColor(ClautoDesign.ink)]
        view.textContainerInset = NSSize(width: 12, height: 12); view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.focusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.focused = focused
        }
        view.setAccessibilityLabel(label); view.string = text; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = enabled
            scroll.backgroundColor = NSColor(ClautoDesign.sheet)
            view.textColor = NSColor(ClautoDesign.ink); view.backgroundColor = NSColor(ClautoDesign.sheet)
            view.insertionPointColor = NSColor(ClautoDesign.ink)
            view.font = ClautoDesign.nativeFont(15)
            view.selectedTextAttributes = [.backgroundColor: NSColor(ClautoDesign.citron), .foregroundColor: NSColor(ClautoDesign.onAccent)]
            view.setAccessibilityLabel(label)
            if view.string != text {
                let selection = view.selectedRange(); view.string = text
                let count = (text as NSString).length, start = min(selection.location, (text as NSString).length)
                view.setSelectedRange(NSRange(location: start, length: min(selection.length, count - start)))
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClautoNativeTextArea
        init(_ parent: ClautoNativeTextArea) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
    }
}

private final class ClautoNativeTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); focusChanged?(result); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { focusChanged?(false) }; return result }
}
private final class ClautoScroller: NSScroller {
    override func drawKnob() {
        NSColor(ClautoDesign.quiet).setFill()
        NSBezierPath(rect: rect(for: .knob).insetBy(dx: 4, dy: 0)).fill()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

struct ClautoToggle: View {
    var title: String
    @Binding var isOn: Bool
    var body: some View {
        if ClautoThemeStore.shared.palette.controls == .native {
            Toggle(title,isOn: $isOn).toggleStyle(.switch)
        } else {
            Button { isOn.toggle() } label: {
                HStack(spacing: ClautoThemeStore.shared.palette.spacing) {
                    indicator
                    Text(title).font(ClautoDesign.body).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
            }.buttonStyle(ClautoInlineButtonStyle()).foregroundStyle(ClautoDesign.ink)
                .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
        }
    }
    @ViewBuilder private var indicator: some View {
        if ClautoThemeStore.shared.palette.controls == .slider {
            ZStack(alignment: isOn ? .trailing:.leading) {
                ClautoThemedShape(palette: ClautoThemeStore.shared.palette).fill(isOn ? ClautoDesign.citron:ClautoDesign.soft)
                Circle().fill(ClautoDesign.ink).padding(4).frame(width: 24,height: 24)
            }.frame(width: 42,height: 24)
                .overlay(ClautoThemedShape(palette: ClautoThemeStore.shared.palette).stroke(ClautoDesign.rule,lineWidth: ClautoThemeStore.shared.palette.geometry.stroke))
        } else {
            ZStack {
                ClautoThemedShape(palette: ClautoThemeStore.shared.palette).fill(isOn ? ClautoDesign.rail:ClautoDesign.sheet)
                if isOn { ClautoIcon(.check,size: 15).foregroundStyle(ClautoDesign.citron) }
            }.frame(width: 20,height: 20)
                .overlay(ClautoThemedShape(palette: ClautoThemeStore.shared.palette).stroke(ClautoDesign.quiet,lineWidth: ClautoThemeStore.shared.palette.geometry.stroke))
        }
    }
}

/// Choices expand inline so the option surface is also part of Clauto's design.
struct ClautoChoice<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(Value, String)]
    @State private var expanded: Bool
    @FocusState private var triggerFocused: Bool
    @FocusState private var focusedOption: Value?
    init(title: String, selection: Binding<Value>, options: [(Value, String)], expandedByDefault: Bool = false) {
        self.title = title; self._selection = selection; self.options = options
        self._expanded = State(initialValue: expandedByDefault)
    }
    private var chosenLabel: String { options.first { $0.0 == selection }?.1 ?? "Choose…" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            Button { expanded.toggle(); if expanded { focusedOption = .some(selection) } } label: {
                HStack { Text(chosenLabel).lineLimit(2); Spacer(minLength: 8)
                    ClautoIcon(.arrow, size: 15).rotationEffect(.degrees(expanded ? -90 : 90))
                }.font(ClautoDesign.body).padding(11).background(ClautoDesign.sheet)
                    .overlay(Rectangle().stroke(ClautoDesign.rule, lineWidth: 1))
            }.buttonStyle(ClautoInlineButtonStyle()).focused($triggerFocused)
                .accessibilityLabel(title).accessibilityValue(chosenLabel)
                .accessibilityHint(expanded ? "Choices are expanded." : "Press to show choices. Arrow keys change the choice.")
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(options, id: \.0) { value, label in
                            Button { selection = value; expanded = false; triggerFocused = true } label: {
                                HStack { Text(label).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 14)
                                    if selection == value { ClautoIcon(.check, size: 16) }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(ClautoInlineButtonStyle(selected: selection == value))
                                .focused($focusedOption, equals: value)
                                .accessibilityLabel(label).accessibilityAddTraits(selection == value ? .isSelected : [])
                        }
                    }.padding(6)
                }.scrollIndicators(.hidden).frame(height: min(240, CGFloat(options.count) * 44 + 12))
                    .background(ClautoDesign.sheet).overlay(Rectangle().stroke(ClautoDesign.rule, lineWidth: 1))
                    .onKeyPress(.escape) { expanded = false; triggerFocused = true; return .handled }
                    .onKeyPress(.downArrow) { focusStep(1); return .handled }
                    .onKeyPress(.upArrow) { focusStep(-1); return .handled }
            }
        }.font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func step(_ direction: Int) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.0 == selection } ?? 0
        selection = options[max(0, min(options.count - 1, index + direction))].0
    }
    private func focusStep(_ direction: Int) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.0 == focusedOption } ?? 0
        focusedOption = options[max(0, min(options.count - 1, index + direction))].0
    }
}

struct ClautoSegments: View {
    @Binding var selection: String
    var options: [(String, ClautoIconName)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, icon in
                Button { selection = value } label: {
                    HStack(spacing: 7) { ClautoIcon(icon, size: 17); Text(value) }
                        .font(ClautoDesign.type(14, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 12)
                        .foregroundStyle(selection == value ? ClautoDesign.railText : ClautoDesign.quiet)
                        .background(selection == value ? ClautoDesign.rail : .clear)
                }.buttonStyle(ClautoInlineButtonStyle()).accessibilityLabel(value)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }.overlay(Rectangle().stroke(ClautoDesign.rule, lineWidth: 1))
    }
}

struct ClautoDisclosure<Content: View>: View {
    var title: String
    @State private var expanded: Bool
    @ViewBuilder var content: Content
    init(_ title: String, expandedByDefault: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content(); _expanded = State(initialValue: expandedByDefault)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack { Text(title).font(ClautoDesign.type(15, weight: .semibold)); Spacer()
                    ClautoIcon(.arrow, size: 15).rotationEffect(.degrees(expanded ? 90 : 0))
                }.padding(.vertical, 9)
            }.buttonStyle(ClautoInlineButtonStyle()).accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content }
        }.foregroundStyle(ClautoDesign.ink)
    }
}

struct ClautoSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var label: String
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    private var span: Double { max(.leastNonzeroMagnitude, range.upperBound - range.lowerBound) }
    private var fraction: Double { value.isFinite ? max(0, min(1, (value - range.lowerBound) / span)) : 0 }
    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 14)
            ZStack(alignment: .leading) {
                Rectangle().fill(ClautoDesign.rule).frame(height: 3).padding(.horizontal, 7)
                Rectangle().fill(ClautoDesign.rail).frame(width: width * fraction, height: 3).padding(.leading, 7)
                CutCorner(cut: 3).fill(ClautoDesign.rail).frame(width: 14, height: 18).offset(x: width * fraction)
            }.frame(height: 30).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { point in
                    guard enabled else { return }; focused = true
                    value = range.lowerBound + max(0, min(1, (point.location.x - 7) / width)) * span
                })
        }.frame(height: 30).overlay(Rectangle().stroke(focused ? ClautoDesign.ink : .clear, lineWidth: ClautoThemeStore.shared.palette.geometry.focusStroke))
            .focusable(enabled).focused($focused).focusEffectDisabled()
            .onKeyPress(.leftArrow) { adjust(-1); return .handled }.onKeyPress(.rightArrow) { adjust(1); return .handled }
            .onKeyPress(.downArrow) { adjust(-1); return .handled }.onKeyPress(.upArrow) { adjust(1); return .handled }
            .accessibilityElement().accessibilityLabel(label).accessibilityValue(String(format: "%.2f", value))
            .accessibilityAdjustableAction { direction in
                if direction == .increment { adjust(1) } else if direction == .decrement { adjust(-1) }
            }.accessibilityRepresentation { Slider(value: $value, in: range, step: span / 100) { Text(label) } }
            .opacity(enabled ? 1 : 0.65)
    }
    private func adjust(_ direction: Double) {
        guard enabled else { return }
        value = max(range.lowerBound, min(range.upperBound, value + direction * span / 100))
    }
}

/// A single stepped loading signal. It makes no claim about percentage complete.
struct ClautoActivity: View {
    var label: String
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: reducedMotion)) { timeline in
            let phase = reducedMotion ? 1 : Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 3
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(0..<3) { index in Rectangle().fill(index == phase ? ClautoDesign.rail : ClautoDesign.rule).frame(width: 9, height: 12) }
                }.accessibilityHidden(true)
                Text(label).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct ClautoEmpty: View {
    var title: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClautoEmblem(bracketColor: ClautoDesign.rail, stripColor: ClautoDesign.citron).frame(width: 72, height: 72)
            Text(title).font(ClautoDesign.type(34, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if !detail.isEmpty { Text(detail).font(ClautoDesign.type(16)).foregroundStyle(ClautoDesign.quiet).frame(maxWidth: 490, alignment: .leading) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
