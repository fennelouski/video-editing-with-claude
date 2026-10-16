import CoreGraphics

enum FontOutlineGeometry {
    /// TrueType contours may start off-curve and imply an on-curve midpoint
    /// between successive control points. Preserve those quadratic segments.
    static func path(_ outline: FontGlyphOutline) throws -> CGPath {
        try outline.validate();let path = CGMutablePath()
        func point(_ value: FontOutlinePoint) -> CGPoint { .init(x: value.x,y: value.y) }
        func midpoint(_ a: CGPoint,_ b: CGPoint) -> CGPoint { .init(x: (a.x+b.x)/2,y: (a.y+b.y)/2) }
        for contour in outline.contours {
            guard let first = contour.first,let last = contour.last else { continue }
            let start: CGPoint,remaining: [FontOutlinePoint]
            if first.onCurve { start = point(first);remaining = Array(contour.dropFirst()) }
            else if last.onCurve { start = point(last);remaining = Array(contour.dropLast()) }
            else { start = midpoint(point(first),point(last));remaining = contour }
            path.move(to: start);var index = 0
            while index < remaining.count {
                let current = remaining[index]
                if current.onCurve { path.addLine(to: point(current));index += 1 }
                else {
                    let next = index+1 < remaining.count ? remaining[index+1]:nil
                    if let next,next.onCurve { path.addQuadCurve(to: point(next),control: point(current));index += 2 }
                    else { path.addQuadCurve(to: next.map { midpoint(point(current),point($0)) } ?? start,control: point(current));index += 1 }
                }
            }
            path.closeSubpath()
        }
        return path
    }
}
