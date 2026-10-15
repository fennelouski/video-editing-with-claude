import SwiftUI
import AppKit
import Observation

@MainActor @Observable final class ClautoThemeStore {
    static let shared = ClautoThemeStore()
    private(set) var selected: ClautoThemeID
    private(set) var systemDark: Bool
    private(set) var systemAppearanceRevision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var colorObservation: NSObjectProtocol?
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ProcessInfo.processInfo.environment["CLAUTO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
        selected = self.defaults.string(forKey: "ClautoTheme").flatMap(ClautoThemeID.init(rawValue:)) ?? .homey
        systemDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance,options: [.new]) { [weak self] _,_ in
            Task { @MainActor [weak self] in self?.refreshSystemAppearance() }
        }
        colorObservation = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification,object: nil,queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSystemAppearance() }
        }
    }
    deinit { if let colorObservation { NotificationCenter.default.removeObserver(colorObservation) } }
    private func refreshSystemAppearance() {
        systemDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua
        systemAppearanceRevision += 1
    }
    var palette: ClautoThemePalette { .make(selected) }
    var resolvedColorScheme: ColorScheme { (selected == .standard ? systemDark:palette.dark) ? .dark:.light }
    var nativeAppearance: NSAppearance? {
        selected == .standard ? nil:NSAppearance(named: palette.dark ? .darkAqua:.aqua)
    }
    func applyNativeAppearance(to window: NSWindow) {
        let desired = nativeAppearance
        if window.appearance?.name != desired?.name { window.appearance = desired }
    }
    func choose(_ theme: ClautoThemeID) { selected = theme; defaults.set(theme.rawValue,forKey: "ClautoTheme") }
}
extension ThemeRGB {
    var color: Color { Color(red: red,green: green,blue: blue) }
}
struct ClautoThemeSurface: View {
    var body: some View {
        let palette = ClautoThemeStore.shared.palette
        ZStack {
            ClautoDesign.paper
            if palette.treatment == .wood || palette.treatment == .paper {
                Canvas { context,size in
                    for row in stride(from: 8.0,to: size.height,by: palette.treatment == .wood ? 14.0:28.0) {
                        var line = Path(); line.move(to: .init(x: 0,y: row)); line.addLine(to: .init(x: size.width,y: row+2))
                        context.stroke(line,with: .color(palette.border.color.opacity(0.055)),lineWidth: 1)
                    }
                }
            } else if [.layered,.summer,.glass,.neon].contains(palette.treatment) {
                LinearGradient(colors: [palette.accent.color.opacity(0.10),.clear,palette.sidebar.color.opacity(0.08)],startPoint: .topLeading,endPoint: .bottomTrailing)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Native controls must receive the same scheme in the current update, rather
/// than briefly retaining a dark label over a newly light authored surface.
struct ClautoThemeAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme,ClautoThemeStore.shared.resolvedColorScheme)
            .background(ClautoNativeThemeAppearance(name: ClautoThemeStore.shared.nativeAppearance?.name).frame(width: 0,height: 0))
    }
}
/// Each hosting root, including sheets without authored window controls, owns
/// its native appearance. Standard inherits AppKit; detached video stays dark.
private struct ClautoNativeThemeAppearance: NSViewRepresentable {
    let name: NSAppearance.Name?
    final class AppearanceView: NSView {
        var name: NSAppearance.Name?
        func apply() {
            guard let window, window.appearance?.name != name else { return }
            window.appearance = name.flatMap(NSAppearance.init(named:))
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    }
    func makeNSView(context: Context) -> AppearanceView { let view = AppearanceView(); view.name = name; return view }
    func updateNSView(_ view: AppearanceView,context: Context) { view.name = name; view.apply() }
}
extension View {
    func clautoThemeAppearance() -> some View { modifier(ClautoThemeAppearance()) }
}
