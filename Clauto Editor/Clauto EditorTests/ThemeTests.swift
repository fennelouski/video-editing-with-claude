import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct ThemeTests {
    @Test func semanticTextContrastAcrossAllThemes() {
        for id in ClautoThemeID.allCases {
            let p = ClautoThemePalette.make(id)
            for background in [p.background,p.surface,p.subtle] {
                #expect(p.ink.contrast(background) >= 4.5, "\(id) primary text")
                #expect(p.muted.contrast(background) >= 4.5, "\(id) secondary text")
                #expect(p.error.contrast(background) >= 4.5, "\(id) errors")
            }
            #expect(p.sidebarInk.contrast(p.sidebar) >= 4.5, "\(id) navigation")
            #expect(p.accentInk.contrast(p.accent) >= 4.5, "\(id) selected/accent text")
        }
    }
    @Test func wcagReferenceAndOriginalThemeIDs() throws {
        #expect(abs(ThemeRGB(value: 0).contrast(.init(value: 0xFFFFFF))-21) < 0.00001)
        #expect(ClautoThemeID.allCases.count == 11)
        #expect(Set(ClautoThemeID.allCases.map(\.rawValue)).count == 11)
        for id in ClautoThemeID.allCases {
            #expect(try JSONDecoder().decode(ClautoThemeID.self,from: JSONEncoder().encode(id)) == id)
        }
        #expect(ClautoThemeID(rawValue: "unknown") == nil)
    }
}
