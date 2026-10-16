import Foundation
import CoreText
import CoreGraphics

struct FontPreviewLayout {
    var paths: [CGPath]
    var missing: [String]
    var height: Double
    var width: Double
    var glyphs: [CGGlyph]
}
enum FontPreviewGeometry {
    /// Resolve the chosen font's own cmap and outlines. CoreText Text/CTLine
    /// fallback is intentionally bypassed; unmapped scalars draw this font's
    /// .notdef outline, with a separate list of missing characters.
    static func layout(_ text: String,font: CTFont,width: Double) throws -> FontPreviewLayout {
        guard text.unicodeScalars.count<=1024,width.isFinite,(1...10000).contains(width) else { throw WorkflowFailure.invalid("Preview up to 1024 characters in a bounded text area.") }
        let ascent = CTFontGetAscent(font),descent = CTFontGetDescent(font),line = max(1,ascent+descent+CTFontGetLeading(font))
        var x = 0.0,baseline = ascent,paths: [CGPath] = [],missing: [String] = [],glyphs: [CGGlyph] = []
        for scalar in text.unicodeScalars {
            if scalar.value==10 { x = 0;baseline += line;continue }
            if scalar.value==13 { continue }
            let characters = Array(String(scalar).utf16);var mapped = [CGGlyph](repeating: 0,count: characters.count)
            _ = CTFontGetGlyphsForCharacters(font,characters,&mapped,characters.count)
            var glyph = mapped.first(where: { $0 != 0 }) ?? 0,advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font,.horizontal,&glyph,&advance,1)
            guard advance.width.isFinite,advance.width>=0 else { throw ProjectFailure.invalidProject }
            if x>0,x+advance.width>width { x = 0;baseline += line }
            if glyph==0,!missing.contains(String(scalar)) { missing.append(String(scalar)) }
            if let path = CTFontCreatePathForGlyph(font,glyph,nil) {
                var transform = CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: x,ty: baseline)
                if let positioned = path.copy(using: &transform) { paths.append(positioned) }
            }
            glyphs.append(glyph);x += advance.width
        }
        let bounds = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) },dx = bounds.isNull ? 0:max(0,-bounds.minX),dy = bounds.isNull ? 0:max(0,-bounds.minY)
        if dx>0 || dy>0 { paths = paths.compactMap { path in var t = CGAffineTransform(translationX: dx,y: dy);return path.copy(using: &t) } }
        return .init(paths: paths,missing: missing,height: max(baseline+descent,bounds.isNull ? 0:bounds.maxY+dy),width: max(width,bounds.isNull ? 0:bounds.maxX+dx),glyphs: glyphs)
    }
}
