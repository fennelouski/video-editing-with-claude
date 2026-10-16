import SwiftUI

struct FontOutlineEditor: View {
    @Bindable var controller: FontStudioController
    let glyph: FontGlyph
    @State private var contour = 0
    @State private var point = 0
    @State private var x = ""
    @State private var y = ""
    @State private var onCurve = true
    @State private var advance = ""
    @State private var issue: String?
    private var selected: FontOutlinePoint? {
        guard glyph.outline.contours.indices.contains(contour),glyph.outline.contours[contour].indices.contains(point) else { return nil }
        return glyph.outline.contours[contour][point]
    }
    var body: some View {
        HStack(alignment: .top,spacing: 24) {
            VStack(alignment: .leading,spacing: 10) {
                Canvas { context,size in
                    guard let outline = try? FontOutlineGeometry.path(glyph.outline) else { return }
                    let bounds = outline.boundingBoxOfPath.union(CGRect(x: 0,y: 0,width: max(1,glyph.outline.advance),height: 1000)),scale = min((size.width-30)/max(1,bounds.width),(size.height-30)/max(1,bounds.height))
                    let transform = CGAffineTransform(a: scale,b: 0,c: 0,d: -scale,tx: 15-bounds.minX*scale,ty: size.height-15+bounds.minY*scale)
                    context.fill(Path(outline).applying(transform),with: .color(ClautoDesign.ink),style: .init(eoFill: false))
                    if let selected {
                        let p = CGPoint(x: selected.x,y: selected.y).applying(transform)
                        context.fill(Path(ellipseIn: CGRect(x: p.x-5,y: p.y-5,width: 10,height: 10)),with: .color(ClautoDesign.ember))
                    }
                }.frame(height: 280).background(ClautoDesign.soft).accessibilityLabel("Character \(glyph.character), \(glyph.outline.contours.count) outline contours. Numeric controls edit each point.")
                Text(glyph.provenanceLabel).font(ClautoDesign.caption)
                Text("Glyph revision \(glyph.revisionID.uuidString.prefix(8))").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading,spacing: 12) {
                if !glyph.outline.contours.isEmpty {
                    ClautoChoice(title: "Contour",selection: $contour,options: glyph.outline.contours.indices.map { ($0,"Contour \($0+1)") })
                    if glyph.outline.contours.indices.contains(contour) {
                        ClautoChoice(title: "Point",selection: $point,options: glyph.outline.contours[contour].indices.map { ($0,"Point \($0+1)") })
                    }
                    HStack { ClautoField(label: "X units",text: $x,placeholder: "0");ClautoField(label: "Y units",text: $y,placeholder: "0") }
                    ClautoToggle(title: "On curve (off means quadratic control)",isOn: $onCurve)
                    ClautoAction("Apply point") {
                        guard let x = Int(x),let y = Int(y),(-4000...4000).contains(x),(-4000...4000).contains(y) else { issue = "Enter X and Y from −4000 to 4000.";return }
                        issue = nil;controller.editPoint(glyphID: glyph.id,contour: contour,point: point,x: x,y: y,onCurve: onCurve)
                    }
                }
                ClautoField(label: "Character advance (0–4000)",text: $advance,placeholder: "600")
                ClautoAction("Apply width") {
                    guard let width = Int(advance),(0...4000).contains(width) else { issue = "Enter a width from 0 to 4000.";return }
                    issue = nil;controller.setAdvance(glyphID: glyph.id,advance: width)
                }
                if let issue { Text(issue).foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption) }
                Text("Point and width edits make a new glyph revision. Rebuild to make a new font; earlier font files stay available.").font(ClautoDesign.caption)
            }.frame(width: 310)
        }.onAppear { reset() }.onChange(of: contour) { point = 0;reset() }.onChange(of: point) { reset() }.onChange(of: glyph.revisionID) { reset() }
    }
    private func reset() { x = selected.map { String($0.x) } ?? "";y = selected.map { String($0.y) } ?? "";onCurve = selected?.onCurve ?? true;advance = String(glyph.outline.advance) }
}
