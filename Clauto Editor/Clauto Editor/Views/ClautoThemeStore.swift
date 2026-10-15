import SwiftUI
import AppKit
import Observation

@MainActor @Observable final class ClautoThemeStore {
    static let shared = ClautoThemeStore()
    private(set) var selected: ClautoThemeID
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ProcessInfo.processInfo.environment["CLAUTO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
        selected = self.defaults.string(forKey: "ClautoTheme").flatMap(ClautoThemeID.init(rawValue:)) ?? .homey
    }
    var palette: ClautoThemePalette { .make(selected) }
    var preferredColorScheme: ColorScheme? { selected == .standard ? nil : palette.dark ? .dark : .light }
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
