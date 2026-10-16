import Foundation
import CoreGraphics
import CoreText

enum GraphicTypography {
    private static let stored: Result<[String:Data],any Error> = Result {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let font = bundle.url(forResource: "ClautoWorkSans",withExtension: "ttf"),let license = bundle.url(forResource: "WorkSans-OFL",withExtension: "txt") else { throw WorkflowFailure.invalid("The app's bundled graphic typography is missing. Reinstall this build to restore it.") }
        let bytes = try SourceRenderDirectory.open(font.deletingLastPathComponent()).read(font.lastPathComponent,limit: 16*1024*1024)
        let text = try SourceRenderDirectory.open(license.deletingLastPathComponent()).read(license.lastPathComponent,limit: 65536)
        guard CGDataProvider(data: bytes as CFData).flatMap(CGFont.init) != nil,String(data: text,encoding: .utf8)?.contains("SIL OPEN FONT LICENSE")==true else { throw ProjectFailure.invalidProject }
        return ["annotation-font.ttf":bytes,"annotation-OFL.txt":text]
    }
    static func files() throws -> [String:Data] { try stored.get() }
    static func font(_ bytes: Data,size: Double) throws -> CTFont {
        guard let provider = CGDataProvider(data: bytes as CFData),let font = CGFont(provider) else { throw CutoutFailure.changedSource }
        return CTFontCreateWithGraphicsFont(font,size,nil,nil)
    }
}

enum GraphicFrameCompositor {
    static func composite(_ raster: CutoutRaster,frame: GraphicBuiltFrame,scene: GraphicScene,index: Int,assets: GraphicResolvedAssets) throws -> CutoutRaster {
        try raster.validate();try scene.validate();try Task.checkCancellation()
        let width = raster.width,height = raster.height
        let annotationBytes = try assets.files["annotation-font.ttf"] ?? GraphicTypography.files()["annotation-font.ttf"]!
        guard width==scene.width,height==scene.height else { throw ProjectFailure.invalidProject }
        var pixels = Data(count: width*height*4)
        try pixels.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CutoutFailure.invalidImage }
            context.setBlendMode(.copy);context.draw(try CutoutImageIO.image(raster),in: .init(x: 0,y: 0,width: width,height: height));context.setBlendMode(.normal)
            for layer in scene.imageLayers where layer.transform.active(index) {
                guard let image = assets.images[layer.id] else { throw CutoutFailure.changedSource }
                let t = layer.transform;context.saveGState();context.setAlpha(t.opacity)
                context.translateBy(x: t.x*Double(width),y: (1-t.y)*Double(height));context.rotate(by: -t.rotationDegrees*Double.pi/180)
                context.draw(try CutoutImageIO.image(image),in: .init(x: -t.width*Double(width)/2,y: -t.height*Double(height)/2,width: t.width*Double(width),height: t.height*Double(height)));context.restoreGState()
            }
            for layer in scene.textLayers where layer.transform.active(index) {
                let t = layer.transform,chosen: CTFont
                if layer.font != nil {
                    guard let bytes = assets.fonts[layer.id],let provider = CGDataProvider(data: bytes as CFData),let font = CGFont(provider) else { throw CutoutFailure.changedSource }
                    chosen = CTFontCreateWithGraphicsFont(font,layer.fontSize*Double(height),nil,nil)
                } else { chosen = try GraphicTypography.font(annotationBytes,size: layer.fontSize*Double(height)) }
                context.saveGState();context.setAlpha(t.opacity);context.translateBy(x: t.x*Double(width),y: (1-t.y)*Double(height));context.rotate(by: -t.rotationDegrees*Double.pi/180)
                try draw(layer.text,font: chosen,color: layer.color,in: .init(x: -t.width*Double(width)/2,y: -t.height*Double(height)/2,width: t.width*Double(width),height: t.height*Double(height)),context: context,exactFont: true);context.restoreGState()
            }
            for label in frame.annotations {
                let font = try GraphicTypography.font(annotationBytes,size: max(9,label.size))
                let box = CGRect(x: label.x,y: Double(height)-label.y-max(16,label.size*1.8),width: Double(width)-label.x-8,height: max(16,label.size*1.8))
                if label.plate {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: label.text,attributes: [NSAttributedString.Key(kCTFontAttributeName as String):font]))
                    let contentWidth = min(box.width,CTLineGetTypographicBounds(line,nil,nil,nil)+4)
                    context.setFillColor(CGColor(srgbRed: 0.96,green: 0.94,blue: 0.87,alpha: 0.96));context.fill(CGRect(x: box.minX-2,y: box.minY,width: contentWidth+4,height: box.height))
                }
                try draw(label.text,font: font,color: label.color,in: box,context: context,exactFont: true,requireFullText: label.requireFullText)
            }
            // Validation and declared assumptions are part of the pixels, not
            // metadata that can disappear when the movie is used elsewhere.
            let footer = scene.validationLabel+(scene.assumptions.isEmpty ? "":"\nAssumptions: "+scene.assumptions.map(\.text).joined(separator: "; "))
            let footerFont = try GraphicTypography.font(annotationBytes,size: max(10,Double(height)*0.025))
            let attributed = NSAttributedString(string: footer,attributes: [NSAttributedString.Key(kCTFontAttributeName as String):footerFont])
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(attributed),CFRange(location: 0,length: attributed.length),nil,CGSize(width: Double(width)*0.95-12,height: .greatestFiniteMagnitude),nil)
            let box = CGRect(x: Double(width)*0.025,y: Double(height)*0.02,width: Double(width)*0.95,height: min(Double(height)*0.19,max(24,ceil(suggested.height)+12)))
            context.setFillColor(CGColor(srgbRed: 0.96,green: 0.94,blue: 0.87,alpha: 0.96));context.fill(box)
            try draw(footer,font: footerFont,color: .init(r: 0.1,g: 0.15,b: 0.12),in: box.insetBy(dx: 6,dy: 4),context: context,exactFont: true,requireFullText: true)
        }
        pixels.withUnsafeMutableBytes { memory in
            let values = memory.bindMemory(to: UInt8.self)
            for i in stride(from: 0,to: values.count,by: 4) {
                let a = Int(values[i+3]);if a>0 && a<255 { for channel in 0..<3 { values[i+channel] = UInt8(min(255,(Int(values[i+channel])*255+a/2)/a)) } }
            }
        }
        try Task.checkCancellation();return .init(width: width,height: height,rgba: pixels)
    }
    private static func draw(_ text: String,font: CTFont,color: GraphicColor,in box: CGRect,context: CGContext,exactFont: Bool = false,requireFullText: Bool = false) throws {
        guard !text.isEmpty,box.width>0,box.height>0 else { return }
        let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(srgbRed: color.r,green: color.g,blue: color.b,alpha: color.a)]
        let string = NSAttributedString(string: text,attributes: attributes),setter = CTFramesetterCreateWithAttributedString(string),path = CGPath(rect: box,transform: nil),frame = CTFramesetterCreateFrame(setter,CFRange(location: 0,length: string.length),path,nil)
        if requireFullText || exactFont { guard CTFrameGetVisibleStringRange(frame).length==string.length else { throw WorkflowFailure.invalid("This text does not fit its graphic layer. Shorten it or enlarge the text area/canvas.") } }
        if exactFont {
            let expected = CTFontCopyPostScriptName(font)
            for line in CTFrameGetLines(frame) as! [CTLine] {
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let used = attributes[kCTFontAttributeName] else { throw ProjectFailure.invalidProject }
                    let usedFont = used as! CTFont
                    var glyphs = [CGGlyph](repeating: 0,count: CTRunGetGlyphCount(run));CTRunGetGlyphs(run,CFRange(location: 0,length: 0),&glyphs)
                    guard CTFontCopyPostScriptName(usedFont)==expected,!glyphs.contains(0) else { throw WorkflowFailure.invalid("This font is missing a character. Choose another font or map/generate that character in Font Studio and select its new revision.") }
                }
            }
        }
        context.textMatrix = .identity;CTFrameDraw(frame,context)
    }
}
