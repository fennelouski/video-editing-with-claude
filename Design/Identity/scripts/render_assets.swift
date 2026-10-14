// Rasterize the authored SVG subset with macOS CoreGraphics, AppKit, and CoreText.
// No third-party renderer, network access, application launch, or font installation.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum RenderError: Error { case invalidSVG(String), cannotCreateBitmap, cannotWritePNG }

func color(_ value: String) -> CGColor {
    let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let rgb = UInt32(raw, radix: 16) ?? 0x172925
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
        CGFloat((rgb >> 16) & 255) / 255,
        CGFloat((rgb >> 8) & 255) / 255,
        CGFloat(rgb & 255) / 255, 1
    ])!
}

func tokens(_ source: String, pattern: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return regex.matches(in: source, range: range).map { String(source[Range($0.range, in: source)!]) }
}

func svgPath(_ source: String) throws -> CGPath {
    let parts = tokens(source, pattern: "[MLCQZ]|-?[0-9]+(?:\\.[0-9]+)?")
    let path = CGMutablePath()
    var index = 0
    func point(_ values: [CGFloat], _ offset: Int) -> CGPoint {
        CGPoint(x: values[offset], y: values[offset + 1])
    }
    while index < parts.count {
        let command = parts[index]
        index += 1
        guard let count = ["M": 2, "L": 2, "C": 6, "Q": 4, "Z": 0][command], index + count <= parts.count else {
            throw RenderError.invalidSVG("Unsupported path command")
        }
        let values = parts[index..<(index + count)].compactMap { Double($0).map { CGFloat($0) } }
        guard values.count == count else { throw RenderError.invalidSVG("Invalid path number") }
        index += count
        switch command {
        case "M": path.move(to: point(values, 0))
        case "L": path.addLine(to: point(values, 0))
        case "Q": path.addQuadCurve(to: point(values, 2), control: point(values, 0))
        case "C": path.addCurve(to: point(values, 4), control1: point(values, 0), control2: point(values, 2))
        default: path.closeSubpath()
        }
    }
    return path
}

func drawText(_ value: String, context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat,
              fill: String = "#172925", weight: CGFloat = 400) {
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontNameAttribute: "WorkSans-Regular",
        kCTFontVariationAttribute: [NSNumber(value: 2003265652): NSNumber(value: Double(weight))]
    ] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(fill)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}

final class SVGRenderer: NSObject, XMLParserDelegate {
    let context: CGContext
    var currentColor = "#172925"
    var textAttributes: [String: String]?
    var text = ""
    var failure: Error?

    init(context: CGContext) { self.context = context }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        do {
            switch name {
            case "svg", "g":
                context.saveGState()
                if let style = attributes["style"], let value = style.split(separator: ":").last {
                    currentColor = String(value).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                }
                if let transform = attributes["transform"] {
                    let commands = tokens(transform, pattern: "(?:translate|scale)\\([^)]*\\)")
                    for command in commands {
                        let values = tokens(command, pattern: "-?[0-9]+(?:\\.[0-9]+)?").compactMap(Double.init).map { CGFloat($0) }
                        if command.hasPrefix("translate") {
                            context.translateBy(x: values[0], y: values.count > 1 ? values[1] : 0)
                        } else {
                            context.scaleBy(x: values[0], y: values.count > 1 ? values[1] : values[0])
                        }
                    }
                }
            case "path":
                guard let d = attributes["d"] else { throw RenderError.invalidSVG("Missing path") }
                try paint(svgPath(d), attributes)
            case "rect":
                let value = { (key: String) -> CGFloat in CGFloat(Double(attributes[key] ?? "0") ?? 0) }
                let path = CGPath(rect: CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height")), transform: nil)
                try paint(path, attributes)
            case "text": textAttributes = attributes; text = ""
            default: break
            }
        } catch { failure = error; parser.abortParsing() }
    }

    func paint(_ path: CGPath, _ attributes: [String: String]) throws {
        let resolve = { (value: String) in value == "currentColor" ? self.currentColor : value }
        context.saveGState()
        if let fill = attributes["fill"], fill != "none" {
            context.addPath(path)
            context.setFillColor(color(resolve(fill)))
            context.fillPath()
        }
        if let stroke = attributes["stroke"], stroke != "none" {
            context.addPath(path)
            context.setStrokeColor(color(resolve(stroke)))
            context.setLineWidth(CGFloat(Double(attributes["stroke-width"] ?? "1") ?? 1))
            context.setLineCap(.square)
            context.setLineJoin(.miter)
            context.strokePath()
        }
        context.restoreGState()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textAttributes != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "svg" || name == "g" { context.restoreGState() }
        if name == "text", let attrs = textAttributes {
            drawText(text, context: context, x: CGFloat(Double(attrs["x"] ?? "0") ?? 0),
                     y: CGFloat(Double(attrs["y"] ?? "0") ?? 0), size: CGFloat(Double(attrs["font-size"] ?? "20") ?? 20),
                     fill: attrs["fill"] ?? currentColor, weight: CGFloat(Double(attrs["font-weight"] ?? "400") ?? 400))
            textAttributes = nil
        }
    }
}

func bitmap(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw RenderError.cannotCreateBitmap
    }
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    return context
}

func render(_ source: URL, width: Int, height: Int, viewWidth: CGFloat, viewHeight: CGFloat) throws -> CGImage {
    let context = try bitmap(width: width, height: height)
    context.scaleBy(x: CGFloat(width) / viewWidth, y: CGFloat(height) / viewHeight)
    let delegate = SVGRenderer(context: context)
    let parser = XMLParser(data: try Data(contentsOf: source))
    parser.delegate = delegate
    guard parser.parse(), delegate.failure == nil else { throw delegate.failure ?? RenderError.invalidSVG(source.path) }
    guard let image = context.makeImage() else { throw RenderError.cannotCreateBitmap }
    return image
}

func write(_ image: CGImage, to url: URL) throws {
    guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw RenderError.cannotWritePNG
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw RenderError.cannotWritePNG }
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let identity = repo.appendingPathComponent("Design/Identity", isDirectory: true)
let previews = identity.appendingPathComponent("previews", isDirectory: true)
let appSet = repo.appendingPathComponent("Clauto Editor/Clauto Editor/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let fontURL = repo.appendingPathComponent("assets/fonts/WorkSans[wght].ttf")
var fontError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError) else {
    throw RenderError.invalidSVG("Existing OFL Work Sans could not be registered for this process")
}
try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

let source = identity.appendingPathComponent("app-icon.svg")
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let filename = "clauto-\(size)@\(scale)x.png"
        let image = try render(source, width: pixels, height: pixels, viewWidth: 1024, viewHeight: 1024)
        try write(image, to: appSet.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "clauto-original-design", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: appSet.appendingPathComponent("Contents.json"))

let board = try render(identity.appendingPathComponent("identity-board.svg"), width: 1440, height: 1110,
                       viewWidth: 1440, viewHeight: 1110)
try write(board, to: previews.appendingPathComponent("identity-board.png"))
let icon = try render(source, width: 1024, height: 1024, viewWidth: 1024, viewHeight: 1024)
try write(icon, to: previews.appendingPathComponent("app-icon-1024.png"))

let small = try bitmap(width: 1200, height: 600)
small.setFillColor(color("#F3F0E5"))
small.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
drawText("Clauto at native pixel sizes", context: small, x: 48, y: 65, size: 32, weight: 600)
drawText("Actual-size renders above; 4× / 2× nearest-neighbor enlargement below", context: small, x: 48, y: 103, size: 18, fill: "#52675E")
small.setFillColor(color("#172925"))
small.fill(CGRect(x: 0, y: 342, width: 1200, height: 258))
for (index, pixels) in [16, 20, 24, 32, 48, 64].enumerated() {
    let x = CGFloat(48 + index * 187)
    let image = try render(source, width: pixels, height: pixels, viewWidth: 1024, viewHeight: 1024)
    small.saveGState()
    // CoreGraphics images have a bottom-left origin; compensate in our SVG canvas.
    small.translateBy(x: x, y: 199 + CGFloat(pixels))
    small.scaleBy(x: 1, y: -1)
    small.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    small.restoreGState()
    drawText("\(pixels) px", context: small, x: x, y: 163, size: 18)
    let factor: CGFloat = pixels <= 32 ? 4 : 2
    small.saveGState()
    small.interpolationQuality = .none
    small.translateBy(x: x, y: 374 + CGFloat(pixels) * factor)
    small.scaleBy(x: 1, y: -1)
    small.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(pixels) * factor, height: CGFloat(pixels) * factor))
    small.restoreGState()
}
try write(small.makeImage()!, to: previews.appendingPathComponent("small-size-silhouette.png"))
print("Rendered 10 native macOS app icons, identity board, 1024-pixel preview, and small-size silhouette sheet from SVG sources.")
