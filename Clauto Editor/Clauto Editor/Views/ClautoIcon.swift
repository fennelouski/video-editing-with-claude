// Original Clauto artwork. Generated from Design/Identity/geometry.json.
// Regenerate with: python3 Design/Identity/scripts/generate_identity.py
// No SF Symbols, third-party icon library, or runtime SVG parsing.
import SwiftUI

enum ClautoIconName: String, CaseIterable, Sendable {
    case project, brief, files, cut, conversation, add, folder, open, play, pause, seek, arrow, science, font, cutout, audio, export, check, close, settings, version
}

/// An authored 24-unit icon. Supply the surrounding control's accessible label.
/// Inherits foregroundStyle; the stroke width is expressed in source-grid units.
struct ClautoIcon: View {
    let name: ClautoIconName
    var size: CGFloat
    var strokeWidth: CGFloat?
    init(_ name: ClautoIconName, size: CGFloat = 18, strokeWidth: CGFloat? = nil) {
        self.name = name;self.size = size;self.strokeWidth = strokeWidth
    }
    var body: some View {
        let palette = ClautoThemeStore.shared.palette,style = palette.geometry.icon
        let weight = (strokeWidth ?? CGFloat(palette.geometry.iconStroke))*size/24
        ZStack {
            if style == .badge {
                ClautoThemedShape(palette: palette).fill(ClautoDesign.citron.opacity(0.20))
                ClautoThemedShape(palette: palette).stroke(lineWidth: palette.geometry.stroke*0.6)
            }
            if style == .native {
                Image(systemName: nativeSymbol).font(.system(size: size*0.85,weight: .regular))
            } else {
                ZStack {
                    ClautoIconShape(name: name,filled: false).stroke(style: StrokeStyle(lineWidth: weight,
                        lineCap: style == .rounded || style == .badge ? .round:.square,
                        lineJoin: style == .rounded || style == .badge ? .round:.miter))
                    ClautoIconShape(name: name,filled: true).fill()
                }.padding(style == .badge ? size*0.18:style == .technical ? size*0.1:0)
                if style == .technical {
                    CutCorner(cut: size*0.2).stroke(style: StrokeStyle(lineWidth: weight*0.5,dash: [size*0.15,size*0.12]))
                }
            }
        }.frame(width: size,height: size).accessibilityHidden(true)
    }
    private var nativeSymbol: String {
        switch name {
        case .project,.folder: "folder"
        case .brief: "doc.text"
        case .files: "doc.on.doc"
        case .cut: "scissors"
        case .conversation: "text.bubble"
        case .add: "plus"
        case .open: "arrow.up.forward.square"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .seek: "forward.end"
        case .arrow: "arrow.right"
        case .science: "flask"
        case .font: "textformat"
        case .cutout: "person.crop.rectangle"
        case .audio: "waveform"
        case .export: "square.and.arrow.up"
        case .check: "checkmark"
        case .close: "xmark"
        case .settings: "slider.horizontal.3"
        case .version: "square.stack"
        }
    }
}

/// The exact editable SVG geometry, transformed into the view's local rectangle.
struct ClautoIconShape: Shape {
    let name: ClautoIconName
    var filled = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch name {
        case .project:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 20))
                path.addLine(to: CGPoint(x: 3, y: 6))
                path.addLine(to: CGPoint(x: 10, y: 6))
                path.addLine(to: CGPoint(x: 12, y: 9))
                path.addLine(to: CGPoint(x: 21, y: 9))
                path.addLine(to: CGPoint(x: 21, y: 17))
                path.addLine(to: CGPoint(x: 18, y: 20))
                path.closeSubpath()
                path.move(to: CGPoint(x: 7, y: 13))
                path.addLine(to: CGPoint(x: 17, y: 13))
                path.move(to: CGPoint(x: 7, y: 16))
                path.addLine(to: CGPoint(x: 14, y: 16))
            }
        case .brief:
            if !filled {
                path.move(to: CGPoint(x: 5, y: 3))
                path.addLine(to: CGPoint(x: 16, y: 3))
                path.addLine(to: CGPoint(x: 20, y: 7))
                path.addLine(to: CGPoint(x: 20, y: 21))
                path.addLine(to: CGPoint(x: 5, y: 21))
                path.closeSubpath()
                path.move(to: CGPoint(x: 15, y: 3))
                path.addLine(to: CGPoint(x: 15, y: 8))
                path.addLine(to: CGPoint(x: 20, y: 8))
                path.move(to: CGPoint(x: 8, y: 12))
                path.addLine(to: CGPoint(x: 16, y: 12))
                path.move(to: CGPoint(x: 8, y: 16))
                path.addLine(to: CGPoint(x: 14, y: 16))
            }
        case .files:
            if !filled {
                path.move(to: CGPoint(x: 7, y: 3))
                path.addLine(to: CGPoint(x: 17, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 7))
                path.addLine(to: CGPoint(x: 21, y: 17))
                path.move(to: CGPoint(x: 3, y: 7))
                path.addLine(to: CGPoint(x: 13, y: 7))
                path.addLine(to: CGPoint(x: 17, y: 11))
                path.addLine(to: CGPoint(x: 17, y: 21))
                path.addLine(to: CGPoint(x: 3, y: 21))
                path.closeSubpath()
                path.move(to: CGPoint(x: 12, y: 7))
                path.addLine(to: CGPoint(x: 12, y: 12))
                path.addLine(to: CGPoint(x: 17, y: 12))
            }
        case .cut:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 5))
                path.addLine(to: CGPoint(x: 16, y: 5))
                path.move(to: CGPoint(x: 3, y: 12))
                path.addLine(to: CGPoint(x: 12, y: 12))
                path.move(to: CGPoint(x: 3, y: 19))
                path.addLine(to: CGPoint(x: 8, y: 19))
                path.move(to: CGPoint(x: 21, y: 3))
                path.addLine(to: CGPoint(x: 11, y: 21))
                path.move(to: CGPoint(x: 18, y: 12))
                path.addLine(to: CGPoint(x: 21, y: 12))
                path.move(to: CGPoint(x: 14, y: 19))
                path.addLine(to: CGPoint(x: 21, y: 19))
            }
        case .conversation:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 4))
                path.addLine(to: CGPoint(x: 21, y: 4))
                path.addLine(to: CGPoint(x: 21, y: 17))
                path.addLine(to: CGPoint(x: 10, y: 17))
                path.addLine(to: CGPoint(x: 5, y: 21))
                path.addLine(to: CGPoint(x: 5, y: 17))
                path.addLine(to: CGPoint(x: 3, y: 17))
                path.closeSubpath()
                path.move(to: CGPoint(x: 7, y: 9))
                path.addLine(to: CGPoint(x: 17, y: 9))
                path.move(to: CGPoint(x: 7, y: 12))
                path.addLine(to: CGPoint(x: 14, y: 12))
            }
        case .add:
            if !filled {
                path.move(to: CGPoint(x: 12, y: 4))
                path.addLine(to: CGPoint(x: 12, y: 20))
                path.move(to: CGPoint(x: 4, y: 12))
                path.addLine(to: CGPoint(x: 20, y: 12))
            }
        case .folder:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 20))
                path.addLine(to: CGPoint(x: 3, y: 6))
                path.addLine(to: CGPoint(x: 10, y: 6))
                path.addLine(to: CGPoint(x: 12, y: 9))
                path.addLine(to: CGPoint(x: 21, y: 9))
                path.addLine(to: CGPoint(x: 21, y: 17))
                path.addLine(to: CGPoint(x: 18, y: 20))
                path.closeSubpath()
            }
        case .open:
            if !filled {
                path.move(to: CGPoint(x: 11, y: 4))
                path.addLine(to: CGPoint(x: 4, y: 4))
                path.addLine(to: CGPoint(x: 4, y: 20))
                path.addLine(to: CGPoint(x: 20, y: 20))
                path.addLine(to: CGPoint(x: 20, y: 13))
                path.move(to: CGPoint(x: 12, y: 12))
                path.addLine(to: CGPoint(x: 21, y: 3))
                path.move(to: CGPoint(x: 14, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 10))
            }
        case .play:
            if filled {
                path.move(to: CGPoint(x: 6, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 12))
                path.addLine(to: CGPoint(x: 6, y: 21))
                path.closeSubpath()
            }
        case .pause:
            if filled {
                path.move(to: CGPoint(x: 5, y: 4))
                path.addLine(to: CGPoint(x: 9, y: 4))
                path.addLine(to: CGPoint(x: 9, y: 20))
                path.addLine(to: CGPoint(x: 5, y: 20))
                path.closeSubpath()
                path.move(to: CGPoint(x: 15, y: 4))
                path.addLine(to: CGPoint(x: 19, y: 4))
                path.addLine(to: CGPoint(x: 19, y: 20))
                path.addLine(to: CGPoint(x: 15, y: 20))
                path.closeSubpath()
            }
        case .seek:
            if !filled {
                path.move(to: CGPoint(x: 21, y: 4))
                path.addLine(to: CGPoint(x: 21, y: 20))
            }
            if filled {
                path.move(to: CGPoint(x: 4, y: 4))
                path.addLine(to: CGPoint(x: 17, y: 12))
                path.addLine(to: CGPoint(x: 4, y: 20))
                path.closeSubpath()
            }
        case .arrow:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 12))
                path.addLine(to: CGPoint(x: 21, y: 12))
                path.move(to: CGPoint(x: 14, y: 5))
                path.addLine(to: CGPoint(x: 21, y: 12))
                path.addLine(to: CGPoint(x: 14, y: 19))
            }
        case .science:
            if !filled {
                path.move(to: CGPoint(x: 9, y: 3))
                path.addLine(to: CGPoint(x: 15, y: 3))
                path.move(to: CGPoint(x: 10, y: 3))
                path.addLine(to: CGPoint(x: 10, y: 9))
                path.addLine(to: CGPoint(x: 4, y: 19))
                path.addQuadCurve(to: CGPoint(x: 6, y: 21), control: CGPoint(x: 3, y: 21))
                path.addLine(to: CGPoint(x: 18, y: 21))
                path.addQuadCurve(to: CGPoint(x: 20, y: 19), control: CGPoint(x: 21, y: 21))
                path.addLine(to: CGPoint(x: 14, y: 9))
                path.addLine(to: CGPoint(x: 14, y: 3))
                path.move(to: CGPoint(x: 7, y: 16))
                path.addLine(to: CGPoint(x: 17, y: 16))
            }
            if filled {
                path.move(to: CGPoint(x: 10, y: 18))
                path.addLine(to: CGPoint(x: 12, y: 18))
                path.addLine(to: CGPoint(x: 12, y: 20))
                path.addLine(to: CGPoint(x: 10, y: 20))
                path.closeSubpath()
            }
        case .font:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 20))
                path.addLine(to: CGPoint(x: 9, y: 4))
                path.addLine(to: CGPoint(x: 15, y: 20))
                path.move(to: CGPoint(x: 5.3, y: 14))
                path.addLine(to: CGPoint(x: 12.7, y: 14))
                path.move(to: CGPoint(x: 15, y: 10))
                path.addLine(to: CGPoint(x: 22, y: 10))
                path.move(to: CGPoint(x: 18.5, y: 10))
                path.addLine(to: CGPoint(x: 18.5, y: 20))
            }
        case .cutout:
            if !filled {
                path.move(to: CGPoint(x: 8, y: 3))
                path.addLine(to: CGPoint(x: 3, y: 3))
                path.addLine(to: CGPoint(x: 3, y: 8))
                path.move(to: CGPoint(x: 16, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 8))
                path.move(to: CGPoint(x: 3, y: 16))
                path.addLine(to: CGPoint(x: 3, y: 21))
                path.addLine(to: CGPoint(x: 8, y: 21))
                path.move(to: CGPoint(x: 16, y: 21))
                path.addLine(to: CGPoint(x: 21, y: 21))
                path.addLine(to: CGPoint(x: 21, y: 16))
                path.move(to: CGPoint(x: 9, y: 7))
                path.addLine(to: CGPoint(x: 16, y: 7))
                path.addLine(to: CGPoint(x: 13, y: 12))
                path.addLine(to: CGPoint(x: 16, y: 17))
                path.addLine(to: CGPoint(x: 9, y: 17))
                path.addLine(to: CGPoint(x: 6, y: 12))
                path.closeSubpath()
            }
        case .audio:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 9))
                path.addLine(to: CGPoint(x: 3, y: 15))
                path.move(to: CGPoint(x: 7.5, y: 5))
                path.addLine(to: CGPoint(x: 7.5, y: 19))
                path.move(to: CGPoint(x: 12, y: 8))
                path.addLine(to: CGPoint(x: 12, y: 16))
                path.move(to: CGPoint(x: 16.5, y: 3))
                path.addLine(to: CGPoint(x: 16.5, y: 21))
                path.move(to: CGPoint(x: 21, y: 7))
                path.addLine(to: CGPoint(x: 21, y: 17))
            }
        case .export:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 14))
                path.addLine(to: CGPoint(x: 3, y: 21))
                path.addLine(to: CGPoint(x: 21, y: 21))
                path.addLine(to: CGPoint(x: 21, y: 14))
                path.move(to: CGPoint(x: 12, y: 16))
                path.addLine(to: CGPoint(x: 12, y: 3))
                path.move(to: CGPoint(x: 6, y: 9))
                path.addLine(to: CGPoint(x: 12, y: 3))
                path.addLine(to: CGPoint(x: 18, y: 9))
            }
        case .check:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 12))
                path.addLine(to: CGPoint(x: 9, y: 18))
                path.addLine(to: CGPoint(x: 21, y: 6))
            }
        case .close:
            if !filled {
                path.move(to: CGPoint(x: 5, y: 5))
                path.addLine(to: CGPoint(x: 19, y: 19))
                path.move(to: CGPoint(x: 19, y: 5))
                path.addLine(to: CGPoint(x: 5, y: 19))
            }
        case .settings:
            if !filled {
                path.move(to: CGPoint(x: 3, y: 6))
                path.addLine(to: CGPoint(x: 7, y: 6))
                path.move(to: CGPoint(x: 14, y: 6))
                path.addLine(to: CGPoint(x: 21, y: 6))
                path.move(to: CGPoint(x: 3, y: 12))
                path.addLine(to: CGPoint(x: 12, y: 12))
                path.move(to: CGPoint(x: 19, y: 12))
                path.addLine(to: CGPoint(x: 21, y: 12))
                path.move(to: CGPoint(x: 10, y: 18))
                path.addLine(to: CGPoint(x: 21, y: 18))
            }
            if filled {
                path.move(to: CGPoint(x: 9, y: 3))
                path.addLine(to: CGPoint(x: 12, y: 3))
                path.addLine(to: CGPoint(x: 12, y: 9))
                path.addLine(to: CGPoint(x: 9, y: 9))
                path.closeSubpath()
                path.move(to: CGPoint(x: 14, y: 9))
                path.addLine(to: CGPoint(x: 17, y: 9))
                path.addLine(to: CGPoint(x: 17, y: 15))
                path.addLine(to: CGPoint(x: 14, y: 15))
                path.closeSubpath()
                path.move(to: CGPoint(x: 5, y: 15))
                path.addLine(to: CGPoint(x: 8, y: 15))
                path.addLine(to: CGPoint(x: 8, y: 21))
                path.addLine(to: CGPoint(x: 5, y: 21))
                path.closeSubpath()
            }
        case .version:
            if !filled {
                path.move(to: CGPoint(x: 6, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 18))
                path.move(to: CGPoint(x: 3, y: 6))
                path.addLine(to: CGPoint(x: 18, y: 6))
                path.addLine(to: CGPoint(x: 18, y: 21))
                path.addLine(to: CGPoint(x: 3, y: 21))
                path.closeSubpath()
                path.move(to: CGPoint(x: 6, y: 13))
                path.addLine(to: CGPoint(x: 9, y: 17))
                path.addLine(to: CGPoint(x: 15, y: 10))
            }
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

/// Clauto's cut bracket and revisable strip, for rail or welcome compositions.
/// Color each layer explicitly; the mark does not add a tile or a stock symbol.
struct ClautoEmblem: View {
    var bracketColor: Color
    var stripColor: Color

    var body: some View {
        ZStack {
            ClautoEmblemShape(strip: false).fill(bracketColor)
            ClautoEmblemShape(strip: true).fill(stripColor)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct ClautoEmblemShape: Shape {
    let strip: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if strip {
            path.move(to: CGPoint(x: 470, y: 438))
            path.addLine(to: CGPoint(x: 780, y: 438))
            path.addLine(to: CGPoint(x: 724, y: 552))
            path.addLine(to: CGPoint(x: 414, y: 552))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: 292, y: 244))
            path.addLine(to: CGPoint(x: 778, y: 244))
            path.addLine(to: CGPoint(x: 708, y: 358))
            path.addLine(to: CGPoint(x: 370, y: 358))
            path.addLine(to: CGPoint(x: 370, y: 666))
            path.addLine(to: CGPoint(x: 708, y: 666))
            path.addLine(to: CGPoint(x: 778, y: 780))
            path.addLine(to: CGPoint(x: 292, y: 780))
            path.addQuadCurve(to: CGPoint(x: 244, y: 732), control: CGPoint(x: 244, y: 780))
            path.addLine(to: CGPoint(x: 244, y: 292))
            path.addQuadCurve(to: CGPoint(x: 292, y: 244), control: CGPoint(x: 244, y: 244))
            path.closeSubpath()
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 1024, y: rect.height / 1024))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
