import Foundation

/// All output comes from the source-linked ink plus editable reveal paths. There
/// is no final-frame fill: missed ink remains visible in the coverage report.
struct HandwritingRenderer: Sendable {
    func extract(source: CutoutRaster, recipe: HandwritingRecipe) throws -> CutoutRaster {
        try Task.checkCancellation(); try source.validate(); try recipe.validate(width: source.width, height: source.height)
        let width = source.width, height = source.height, count = width * height
        let pixels = Array(source.rgba), extraction = recipe.extraction
        var mask = [UInt8](repeating: 0, count: count), result = pixels
        for index in 0..<count {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            let offset = index * 4
            if extraction.mode == .sourceAlpha { mask[index] = pixels[offset + 3] }
            else {
                let luminance = (Double(pixels[offset]) * 0.2126 + Double(pixels[offset + 1]) * 0.7152 + Double(pixels[offset + 2]) * 0.0722) / 255
                let ink = extraction.mode == .lightPaper ? 1 - luminance : luminance
                let coverage = max(0, min(1, (ink - extraction.threshold) / extraction.softness))
                mask[index] = UInt8((coverage * Double(pixels[offset + 3])).rounded())
                // A keyed paper edge contains paper RGB. Declared ink color
                // avoids preserving that fringe in a supposedly clean alpha.
                result[offset] = extraction.inkRed; result[offset + 1] = extraction.inkGreen; result[offset + 2] = extraction.inkBlue
            }
        }
        var work = 0
        for stroke in extraction.cleanup {
            let points = stroke.points.map { point($0, width: width, height: height) }
            for index in points.indices {
                try Task.checkCancellation()
                try visitCapsule(a: index == 0 ? points[index] : points[index - 1], b: points[index], radius: stroke.radiusPixels,
                                 width: width, height: height, work: &work) { position, coverage in
                    if stroke.mode == .restore { mask[position] = max(mask[position], UInt8((Double(pixels[position * 4 + 3]) * coverage).rounded())) }
                    else { mask[position] = UInt8((Double(mask[position]) * (1 - coverage)).rounded()) }
                }
            }
        }
        var ink = 0, clear = 0
        for index in 0..<count {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            result[index * 4 + 3] = mask[index]
            if mask[index] > 0 { ink += 1 }; if mask[index] == 0 { clear += 1 }
        }
        guard ink > 0, clear > 0 else {
            throw HandwritingFailure.invalid(extraction.mode == .sourceAlpha
                ? "This image needs both ink and transparent pixels. Choose light/dark paper keying or import a real alpha image."
                : "The paper key found no separate ink and background. Adjust threshold/softness or paint a cleanup correction.")
        }
        return .init(width: width, height: height, rgba: Data(result))
    }

    func render(ink: CutoutRaster, recipe: HandwritingRecipe, frame: Int) throws -> CutoutRaster {
        try Task.checkCancellation(); try ink.validate(); try recipe.validate(width: ink.width, height: ink.height)
        guard frame >= 0, frame < recipe.frameCount else { throw HandwritingFailure.invalid("Choose a frame inside this handwriting animation.") }
        let frame = frame / 2 * 2, width = ink.width, height = ink.height
        var reveal = [UInt8](repeating: 0, count: width * height), work = 0
        for stroke in recipe.strokes {
            try Task.checkCancellation()
            guard frame >= stroke.startFrame else { continue }
            // At the first frame of a path progress is zero. Its last two-frame
            // exposure reaches the endpoint, preserving an exact 2s cadence.
            let raw = stroke.durationFrames == 2 ? 1 : max(0, min(1, Double(frame - stroke.startFrame) / Double(stroke.durationFrames - 2)))
            let progress = stroke.easing == .linear ? raw : raw * raw * (3 - 2 * raw)
            guard progress > 0 else { continue }
            let ordered = stroke.reverse ? Array(stroke.points.reversed()) : stroke.points
            let points = ordered.map { point($0, width: width, height: height) }
            let lengths = points.indices.map { index in index == 0 ? 0 : hypot(points[index].0 - points[index - 1].0, points[index].1 - points[index - 1].1) }
            let length = lengths.reduce(0, +)
            var remaining = length * progress
            if length == 0 {
                try visitCapsule(a: points[0], b: points[0], radius: stroke.maskWidthPixels / 2, width: width, height: height, work: &work) { index, coverage in
                    reveal[index] = max(reveal[index], UInt8((coverage * 255).rounded()))
                }
                continue
            }
            for index in points.indices.dropFirst() {
                guard remaining > 0 else { break }
                let segment = lengths[index], start = points[index - 1], end = points[index]
                let fraction = segment == 0 ? 1 : min(1, remaining / segment)
                let partial = (start.0 + (end.0 - start.0) * fraction, start.1 + (end.1 - start.1) * fraction)
                try visitCapsule(a: start, b: partial, radius: stroke.maskWidthPixels / 2, width: width, height: height, work: &work) { index, coverage in
                    reveal[index] = max(reveal[index], UInt8((coverage * 255).rounded()))
                }
                remaining -= segment
            }
        }
        var result = Array(ink.rgba)
        for index in reveal.indices {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            result[index * 4 + 3] = UInt8((Int(result[index * 4 + 3]) * Int(reveal[index]) + 127) / 255)
        }
        return .init(width: width, height: height, rgba: Data(result))
    }

    func quality(ink: CutoutRaster, recipe: HandwritingRecipe) throws -> HandwritingQuality {
        let final = try render(ink: ink, recipe: recipe, frame: recipe.frameCount - 1)
        let original = Array(ink.rgba), revealed = Array(final.rgba)
        var count = 0, partial = 0, boundary = 0, missing = 0
        for index in 0..<(ink.width * ink.height) {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            let alpha = Int(original[index * 4 + 3]); guard alpha > 0 else { continue }
            count += 1
            if alpha < 255 { partial += 1 }
            let x = index % ink.width, y = index / ink.width
            if x == 0 || x == ink.width - 1 || y == 0 || y == ink.height - 1 { boundary += 1 }
            if Int(revealed[index * 4 + 3]) < alpha - 2 { missing += 1 }
        }
        return .init(inkPixels: count, partialAlphaPixels: partial, boundaryInkPixels: boundary, unrevealedPixels: missing)
    }

    /// Zhang–Suen thinning of an actual-ink occupancy grid. The resulting graph
    /// traversal is an editable hypothesis, never pen telemetry or text OCR.
    func suggestedStrokes(for ink: CutoutRaster, locale: String) throws -> [HandwritingStroke] {
        try ink.validate(); try HandwritingRecipe().validate(width: ink.width, height: ink.height)
        try Task.checkCancellation()
        let scale = max(1, Double(max(ink.width, ink.height)) / 640)
        let width = max(1, Int(ceil(Double(ink.width) / scale))), height = max(1, Int(ceil(Double(ink.height) / scale)))
        let pitch = width + 2, source = Array(ink.rgba)
        var cells = [UInt8](repeating: 0, count: pitch * (height + 2))
        // Max occupancy keeps dots/diacritics that point sampling would discard.
        for y in 0..<ink.height {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<ink.width where source[(y * ink.width + x) * 4 + 3] > 24 {
                let gx = min(width - 1, Int(Double(x) / scale)), gy = min(height - 1, Int(Double(y) / scale))
                cells[(gy + 1) * pitch + gx + 1] = 1
            }
        }
        guard cells.contains(1) else { throw HandwritingFailure.invalid("The image has no visible ink from which to suggest reveal paths.") }
        // A two-pass chamfer distance bounds each suggested brush by the
        // measured local ink thickness, rather than guessing from image size.
        let diagonal = 1.4142135623730951
        var distances = cells.map { $0 == 0 ? 0.0 : Double(width + height) }
        for y in 1...height {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 1...width {
                let index = y * pitch + x; guard cells[index] == 1 else { continue }
                distances[index] = min(distances[index], distances[index - 1] + 1, distances[index - pitch] + 1,
                                       distances[index - pitch - 1] + diagonal, distances[index - pitch + 1] + diagonal)
            }
        }
        for y in stride(from: height, through: 1, by: -1) {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in stride(from: width, through: 1, by: -1) {
                let index = y * pitch + x; guard cells[index] == 1 else { continue }
                distances[index] = min(distances[index], distances[index + 1] + 1, distances[index + pitch] + 1,
                                       distances[index + pitch - 1] + diagonal, distances[index + pitch + 1] + diagonal)
            }
        }
        let offsets = [-pitch, -pitch + 1, 1, pitch + 1, pitch, pitch - 1, -1, -pitch - 1]
        for _ in 0..<320 {
            try Task.checkCancellation(); var changed = false
            for pass in 0..<2 {
                var erase: [Int] = []
                for y in 1...height {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    for x in 1...width {
                        let index = y * pitch + x; guard cells[index] == 1 else { continue }
                        let neighbors = offsets.map { Int(cells[index + $0]) }, sum = neighbors.reduce(0, +)
                        guard (2...6).contains(sum) else { continue }
                        var transitions = 0
                        for position in 0..<8 where neighbors[position] == 0 && neighbors[(position + 1) % 8] == 1 { transitions += 1 }
                        guard transitions == 1 else { continue }
                        let a = pass == 0 ? neighbors[0] * neighbors[2] * neighbors[4] : neighbors[0] * neighbors[2] * neighbors[6]
                        let b = pass == 0 ? neighbors[2] * neighbors[4] * neighbors[6] : neighbors[0] * neighbors[4] * neighbors[6]
                        if a == 0 && b == 0 { erase.append(index) }
                    }
                }
                if !erase.isEmpty { changed = true }; for index in erase { cells[index] = 0 }
            }
            if !changed { break }
        }
        // Stable traversal begins at a leftmost (or RTL rightmost) endpoint and
        // splits branches into independent paths so no jump becomes a wipe.
        let rtl = ["ar", "he", "fa", "ur"].contains(locale.split(separator: "-").first.map(String.init) ?? locale)
        var remaining = Set(cells.indices.filter { cells[$0] == 1 }), paths: [[CutoutPoint]] = [], pathWidths: [Double] = []
        var totalPoints = 0
        while !remaining.isEmpty {
            try Task.checkCancellation()
            guard paths.count < 512, totalPoints < 16_384 else {
                throw HandwritingFailure.invalid("The image contains too many ink branches for an editable path draft. Crop or simplify the artwork, or draw the main reveal paths manually.")
            }
            let endpoints = remaining.filter { index in offsets.reduce(0) { $0 + (remaining.contains(index + $1) ? 1 : 0) } <= 1 }
            let candidates = endpoints.isEmpty ? remaining : Set(endpoints)
            let start = candidates.min { a, b in
                let ax = a % pitch, bx = b % pitch
                if ax != bx { return rtl ? ax > bx : ax < bx }; return a < b
            }!
            var current = start, path: [CutoutPoint] = [], measuredRadius = 0.0
            while true {
                remaining.remove(current)
                measuredRadius = max(measuredRadius, distances[current])
                let x = Double(current % pitch - 1) + 0.5, y = Double(current / pitch - 1) + 0.5
                path.append(.init(x: min(1, max(0, x / Double(width))), y: min(1, max(0, y / Double(height)))))
                let neighbors = offsets.map { current + $0 }.filter { remaining.contains($0) }
                guard let next = neighbors.min(by: { a, b in
                    let ax = a % pitch, bx = b % pitch
                    if ax != bx { return rtl ? ax > bx : ax < bx }; return a < b
                }), path.count < 4096 else { break }
                current = next
            }
            totalPoints += path.count; paths.append(path)
            pathWidths.append(max(6, 2 * scale * (measuredRadius + 1.5)))
        }
        let targetFrames = min(2200, max(48, paths.count * 4)), pathLength = paths.map { path in
            path.indices.dropFirst().reduce(0.0) { value, index in
                value + hypot((path[index].x - path[index - 1].x) * Double(ink.width), (path[index].y - path[index - 1].y) * Double(ink.height))
            }
        }, length = max(1, pathLength.reduce(0, +))
        var strokes: [HandwritingStroke] = [], cursor = 0
        for (index, path) in paths.enumerated() {
            let duration = max(2, Int((Double(targetFrames) * pathLength[index] / length / 2).rounded()) * 2)
            // A generous measured round mask is clipped to the actual ink;
            // cross-letter intersections still require editorial correction.
            let brush = pathWidths[index]
            let stableID = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(index + 1)))!
            strokes.append(.init(id: stableID, points: path, startFrame: cursor, durationFrames: duration,
                                 pauseAfterFrames: 0, reverse: false, easing: .easeInOut, maskWidthPixels: brush))
            cursor += duration
        }
        guard cursor <= 2388 else { throw HandwritingFailure.invalid("This image needs too many reveal exposures. Simplify its paths or choose shorter durations.") }
        return strokes
    }

    private func point(_ point: CutoutPoint, width: Int, height: Int) -> (Double, Double) {
        (point.x * Double(max(0, width - 1)) + 0.5, point.y * Double(max(0, height - 1)) + 0.5)
    }

    private func visitCapsule(a: (Double, Double), b: (Double, Double), radius: Double, width: Int, height: Int,
                              work: inout Int, visit: (Int, Double) -> Void) throws {
        let x0 = max(0, Int(floor(min(a.0, b.0) - radius - 1))), x1 = min(width - 1, Int(ceil(max(a.0, b.0) + radius + 1)))
        let y0 = max(0, Int(floor(min(a.1, b.1) - radius - 1))), y1 = min(height - 1, Int(ceil(max(a.1, b.1) + radius + 1)))
        guard x0 <= x1, y0 <= y1 else { return }
        work += (x1 - x0 + 1) * (y1 - y0 + 1)
        guard work <= 80_000_000 else { throw HandwritingFailure.invalid("These reveal brushes exceed the per-frame work budget. Reduce path points or mask widths and retry.") }
        let dx = b.0 - a.0, dy = b.1 - a.1, length = dx * dx + dy * dy
        for y in y0...y1 {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in x0...x1 {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let t = length == 0 ? 0 : max(0, min(1, ((px - a.0) * dx + (py - a.1) * dy) / length))
                let distance = hypot(px - (a.0 + t * dx), py - (a.1 + t * dy))
                let coverage = max(0, min(1, radius + 0.5 - distance))
                if coverage > 0 { visit(y * width + x, coverage) }
            }
        }
    }
}
