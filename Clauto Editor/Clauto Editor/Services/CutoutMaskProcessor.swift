import Foundation

/// Deterministic correction changes alpha only. Source color bytes are retained.
/// All coordinates refer to the oriented image with a top-left origin.
struct CutoutMaskProcessor: Sendable {
    func render(_ source: CutoutRaster,recipe: CutoutRecipe,detection: CutoutDetection?,manualMask: Data? = nil,
                checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> CutoutPixels {
        try checkCancellation()
        try source.validate(); try recipe.validate(width: source.width,height: source.height)
        let count = source.width*source.height
        var mask = [UInt8](repeating: 0,count: count)
        if let manualMask {
            guard recipe.selectedSubjects.isEmpty, manualMask.count == count,
                  recipe.manualMaskSHA256 == TranscriptSourceMap.sha(manualMask) else { throw CutoutFailure.invalidMask }
            mask = Array(manualMask)
        } else {
            guard recipe.manualMaskSHA256 == nil else { throw CutoutFailure.invalidMask }
            if let detection {
                try detection.validate()
                guard detection.width == source.width, detection.height == source.height,
                      Set(recipe.selectedSubjects).isSubset(of: Set(detection.subjects.map(\.id))) else { throw CutoutFailure.invalidMask }
                for subject in detection.subjects where recipe.selectedSubjects.contains(subject.id) {
                    for (i,value) in subject.mask.enumerated() {
                        if i % 65_536 == 0 { try checkCancellation() }; mask[i] = max(mask[i],value)
                    }
                }
            } else if !recipe.selectedSubjects.isEmpty { throw CutoutFailure.invalidMask }
        }
        for stroke in recipe.strokes { try paint(stroke,mask: &mask,width: source.width,height: source.height,check: checkCancellation) }
        let colors = Array(source.rgba)
        let covered = mask.indices.reduce(0) { $0 + (mask[$1] > 0 && colors[$1*4+3] > 0 ? 1:0) }
        guard covered > 0, covered < count else { throw CutoutFailure.noSubject }
        if recipe.featherPixels > 0 { mask = try feather(mask,width: source.width,height: source.height,radius: recipe.featherPixels,check: checkCancellation) }
        var output = colors
        for i in 0..<count {
            if i % 65_536 == 0 { try checkCancellation() }
            output[i*4+3] = UInt8((Int(colors[i*4+3])*Int(mask[i])+127)/255)
        }
        guard (0..<count).contains(where: { output[$0*4+3] > 0 }) else { throw CutoutFailure.noSubject }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(image: .init(width: source.width,height: source.height,rgba: Data(output)),mask: Data(mask),foregroundPixels: covered,
                     sourceRasterSHA256: TranscriptSourceMap.sha(source.rgba),recipeSHA256: TranscriptSourceMap.sha(try encoder.encode(recipe)))
    }
    private func paint(_ stroke: CutoutBrushStroke,mask: inout [UInt8],width: Int,height: Int,check: @Sendable () throws -> Void) throws {
        let points = stroke.points.map { ($0.x*Double(width),$0.y*Double(height)) }, radius = stroke.radiusPixels
        for index in points.indices {
            try check()
            let a = index == 0 ? points[index]:points[index-1], b = points[index]
            let x0 = max(0,Int(floor(min(a.0,b.0)-radius))), x1 = min(width-1,Int(ceil(max(a.0,b.0)+radius)))
            let y0 = max(0,Int(floor(min(a.1,b.1)-radius))), y1 = min(height-1,Int(ceil(max(a.1,b.1)+radius)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let dx = b.0-a.0, dy = b.1-a.1, length = dx*dx+dy*dy
            for y in y0...y1 {
                if y % 64 == 0 { try check() }
                for x in x0...x1 {
                    let px = Double(x)+0.5, py = Double(y)+0.5
                    let t = length == 0 ? 0:max(0,min(1,((px-a.0)*dx+(py-a.1)*dy)/length))
                    let ex = px-(a.0+t*dx), ey = py-(a.1+t*dy)
                    if ex*ex+ey*ey <= radius*radius { mask[y*width+x] = stroke.mode == .restore ? 255:0 }
                }
            }
        }
    }
    private func feather(_ input: [UInt8],width: Int,height: Int,radius: Int,check: @Sendable () throws -> Void) throws -> [UInt8] {
        // Separable normalized box feather, with clear pixels outside the image.
        // Sliding sums bound work to O(pixels), independent of the brush radius.
        var horizontal = [UInt8](repeating: 0,count: input.count), output = horizontal
        let divisor = 2*radius+1
        for y in 0..<height {
            if y % 64 == 0 { try check() }
            var sum = (0...min(radius,width-1)).reduce(0) { $0+Int(input[y*width+$1]) }
            for x in 0..<width {
                horizontal[y*width+x] = UInt8((sum+divisor/2)/divisor)
                if x-radius >= 0 { sum -= Int(input[y*width+x-radius]) }
                if x+radius+1 < width { sum += Int(input[y*width+x+radius+1]) }
            }
        }
        for x in 0..<width {
            if x % 64 == 0 { try check() }
            var sum = (0...min(radius,height-1)).reduce(0) { $0+Int(horizontal[$1*width+x]) }
            for y in 0..<height {
                output[y*width+x] = UInt8((sum+divisor/2)/divisor)
                if y-radius >= 0 { sum -= Int(horizontal[(y-radius)*width+x]) }
                if y+radius+1 < height { sum += Int(horizontal[(y+radius+1)*width+x]) }
            }
        }
        return output
    }
}
