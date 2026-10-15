import Foundation

enum ClautoThemeID: String, CaseIterable, Codable, Identifiable, Sendable {
    case homey, cozy, standard, minimal, maximal, futuristic, tron, tacoBell, tgif, theOffice, summertimeFine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .homey: "Homey"
        case .cozy: "Cozy"
        case .standard: "Standard"
        case .minimal: "Minimal"
        case .maximal: "Maximal"
        case .futuristic: "Futuristic"
        case .tron: "Tron"
        case .tacoBell: "Taco Bell"
        case .tgif: "TGIF"
        case .theOffice: "The Office"
        case .summertimeFine: "Summertime Fine"
        }
    }
}
struct ThemeRGB: Equatable, Sendable {
    let value: UInt32
    var red: Double { Double((value >> 16)&255)/255 }
    var green: Double { Double((value >> 8)&255)/255 }
    var blue: Double { Double(value&255)/255 }
    var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        return 0.2126*linear(red)+0.7152*linear(green)+0.0722*linear(blue)
    }
    func contrast(_ other: Self) -> Double { (max(luminance,other.luminance)+0.05)/(min(luminance,other.luminance)+0.05) }
    func readable(on background: Self, minimum: Double = 4.5) -> Self {
        guard contrast(background) < minimum else { return self }
        return ThemeRGB(value: 0).contrast(background) >= ThemeRGB(value: 0xFFFFFF).contrast(background) ? .init(value: 0) : .init(value: 0xFFFFFF)
    }
}
struct ClautoThemePalette: Sendable {
    enum Treatment: String, Sendable { case wood, soft, native, plain, layered, glass, neon, diner, paper, summer }
    let id: ClautoThemeID
    let background: ThemeRGB
    let surface: ThemeRGB
    let ink: ThemeRGB
    let muted: ThemeRGB
    let sidebar: ThemeRGB
    let sidebarInk: ThemeRGB
    let accent: ThemeRGB
    let accentInk: ThemeRGB
    let subtle: ThemeRGB
    let border: ThemeRGB
    let error: ThemeRGB
    let treatment: Treatment
    let dark: Bool
    let corner: Double
    let spacing: Double
    static func make(_ id: ClautoThemeID) -> Self {
        let colors: (UInt32,UInt32,UInt32,UInt32,UInt32,UInt32,UInt32,UInt32,Treatment,Bool,Double,Double)
        switch id {
        case .homey: colors = (0xF7F0E3,0xFFF9EF,0x30271F,0x665447,0x573E2C,0xEDBC72,0xE9DECC,0x927963,.wood,false,9,12)
        case .cozy: colors = (0x25272D,0x30333A,0xF7EEE3,0xC3B9AE,0x1C2026,0xD5A578,0x3E4248,0x8C8175,.soft,true,14,14)
        case .standard: colors = (0xF2F2F7,0xFFFFFF,0x1C1C1E,0x59595F,0xE5E5EA,0x0066CC,0xE5E5EA,0x96969F,.native,false,6,10)
        case .minimal: colors = (0xFCFCFA,0xFFFFFF,0x161A18,0x5B605D,0xEDEEEA,0x222B26,0xF0F1ED,0x9FA59F,.plain,false,0,8)
        case .maximal: colors = (0xFBE7F2,0xFFF4CC,0x342044,0x72516F,0x492B73,0xE04F78,0xE9D2F4,0xA16A9B,.layered,false,18,16)
        case .futuristic: colors = (0x101E31,0x1A2B43,0xE5F7FF,0xB1C5D9,0x0A1528,0x60D8F0,0x263C58,0x7596B6,.glass,true,16,12)
        case .tron: colors = (0x07161B,0x0C222A,0xDAFAFF,0xA1C3CF,0x040E12,0x39E5E8,0x153A44,0x47B4C5,.neon,true,2,10)
        case .tacoBell: colors = (0xF4E9FF,0xFFF7FF,0x302044,0x6F537A,0x552C86,0x19BEB6,0xE3CEF4,0x9870AC,.layered,false,12,12)
        case .tgif: colors = (0xFFF5E6,0xFFFDF8,0x2E2020,0x705653,0x6D202C,0xB92E40,0xF0DAD1,0x9B7772,.diner,false,5,12)
        case .theOffice: colors = (0xF1EEDA,0xFFFDEF,0x293437,0x596267,0x394E57,0xD7B75C,0xE3E1D0,0x8A948E,.paper,false,2,10)
        case .summertimeFine: colors = (0xFFF5E5,0xFFFCF3,0x213E59,0x546C7C,0x265578,0xF0A18F,0xE7E7DE,0x839BA9,.summer,false,13,14)
        }
        let bg = ThemeRGB(value: colors.0), surface = ThemeRGB(value: colors.1), ink = ThemeRGB(value: colors.2).readable(on: bg)
        let subtle = ThemeRGB(value: colors.6)
        let muted = ThemeRGB(value: colors.3).readable(on: bg).readable(on: surface).readable(on: subtle), sidebar = ThemeRGB(value: colors.4), accent = ThemeRGB(value: colors.5)
        return .init(id: id,background: bg,surface: surface,ink: ink,muted: muted,sidebar: sidebar,
                     sidebarInk: ThemeRGB(value: 0xFFF8EC).readable(on: sidebar),accent: accent,accentInk: ThemeRGB(value: 0x221E26).readable(on: accent),
                     subtle: subtle,border: ThemeRGB(value: colors.7).readable(on: bg,minimum: 3).readable(on: surface,minimum: 3),error: ThemeRGB(value: colors.9 ? 0xFFB4A1:0xA32D30).readable(on: bg).readable(on: surface).readable(on: subtle),treatment: colors.8,dark: colors.9,corner: colors.10,spacing: colors.11)
    }
}
