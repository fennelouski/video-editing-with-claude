import Foundation
import CoreGraphics
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
    @Test func themesHaveStructuralLanguageBeyondColor() {
        let values = ClautoThemeID.allCases.map { ClautoThemePalette.make($0).geometry }
        #expect(Set(values.map { $0.shape.rawValue }).count>=5)
        #expect(Set(values.map { $0.icon.rawValue }).count>=5)
        #expect(Set(values.map { $0.stroke }).count>=7)
        #expect(Set(values.map { $0.type.rawValue }).count==4)
        #expect(Set(values.map { $0.inset }).count>=5)
        for value in values { #expect(value.stroke>0 && value.focusStroke>value.stroke && value.iconStroke>0) }
        #expect(ClautoThemePalette.make(.standard).geometry.icon == .native)
        #expect(ClautoThemePalette.make(.homey).geometry.icon != .native)
    }
    @Test func controlFamiliesChangeWithTheTheme() {
        #expect(Set(ClautoThemeID.allCases.map { ClautoThemePalette.make($0).controls.rawValue }).count==3)
        #expect(ClautoThemePalette.make(.standard).controls == .native)
        #expect(ClautoThemePalette.make(.cozy).controls == .slider)
        #expect(ClautoThemePalette.make(.homey).controls == .check)
    }
    @Test func videoPlacementUsesVisibleScreenAndNeverChangesCanvasCoordinates() {
        let screen = CGRect(x: -1920,y: 40,width: 1920,height: 1040),size = CGSize(width: 640,height: 380)
        for placement in ReviewVideoPlacement.allCases {
            let frame = placement.frame(size: size,screen: screen)
            #expect(screen.contains(frame) && frame.size==size)
        }
        #expect(ReviewVideoPlacement.topLeft.frame(size: size,screen: screen).minX<ReviewVideoPlacement.topRight.frame(size: size,screen: screen).minX)
        #expect(ReviewVideoPlacement.topLeft.frame(size: size,screen: screen).minY>ReviewVideoPlacement.bottomLeft.frame(size: size,screen: screen).minY)
        #expect(ReviewVideoPlacement.center.frame(size: size,screen: screen).midX==screen.midX)
        #expect(ReviewVideoPlacement.center.frame(size: .init(width: 9000,height: 9000),screen: screen)==screen)
    }

}
