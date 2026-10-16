import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct CutoutDecodedSource: Equatable, Sendable {
    let raster: CutoutRaster
    let originalSHA256: String
    let orientation: Int
}

enum CutoutImageIO {
    static let sourceLimit = 64*1024*1024
    static func decode(_ bytes: Data,encodedLimit: Int = sourceLimit) throws -> CutoutDecodedSource {
        guard encodedLimit > 0,encodedLimit <= 256*1024*1024,!bytes.isEmpty, bytes.count <= encodedLimit,
              let source = CGImageSourceCreateWithData(bytes as CFData,nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_000, height <= 32_000, width*height <= 32_000_000 else { throw CutoutFailure.invalidImage }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:max(width,height),
                kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width == (orientation >= 5 ? height:width), image.height == (orientation >= 5 ? width:height),
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else { throw CutoutFailure.invalidImage }
        var data = Data(count: image.width*image.height*4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy); context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height)); return true
        }
        guard drawn else { throw CutoutFailure.invalidImage }
        // The canonical working raster uses straight alpha. Opaque source color
        // bytes stay exact; the original encoded file is retained separately.
        data.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            for i in stride(from: 0,to: pixels.count,by: 4) {
                let alpha = Int(pixels[i+3])
                if alpha > 0, alpha < 255 {
                    for channel in 0..<3 { pixels[i+channel] = UInt8(min(255,(Int(pixels[i+channel])*255+alpha/2)/alpha)) }
                }
            }
        }
        return .init(raster: .init(width: image.width,height: image.height,rgba: data),originalSHA256: TranscriptSourceMap.sha(bytes),orientation: orientation)
    }
    static func image(_ raster: CutoutRaster) throws -> CGImage {
        try raster.validate()
        guard let provider = CGDataProvider(data: raster.rgba as CFData),
              let result = CGImage(width: raster.width,height: raster.height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: raster.width*4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.last.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent) else { throw CutoutFailure.invalidImage }
        return result
    }
    static func png(_ raster: CutoutRaster) throws -> Data {
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil) else { throw CutoutFailure.invalidImage }
        CGImageDestinationAddImage(writer,try image(raster),[kCGImagePropertyOrientation:1] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CutoutFailure.invalidImage }
        return bytes as Data
    }
    static func maskPNG(_ mask: Data,width: Int,height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 32_000, height <= 32_000, width*height <= 32_000_000, mask.count == width*height else { throw CutoutFailure.invalidMask }
        var pixels = Data(count: width*height*4)
        pixels.withUnsafeMutableBytes { buffer in
            let p = buffer.bindMemory(to: UInt8.self)
            for (i,v) in mask.enumerated() { p[i*4] = v; p[i*4+1] = v; p[i*4+2] = v; p[i*4+3] = 255 }
        }
        return try png(.init(width: width,height: height,rgba: pixels))
    }
    static func manualMask(_ source: CutoutDecodedSource,width: Int,height: Int) throws -> Data {
        let image = source.raster; try image.validate()
        guard image.width == width, image.height == height else { throw CutoutFailure.invalidMask }
        let pixels = Array(image.rgba)
        return Data((0..<(width*height)).map { i in
            let gray = (Int(pixels[i*4])*2126+Int(pixels[i*4+1])*7152+Int(pixels[i*4+2])*722+5000)/10000
            return UInt8((gray*Int(pixels[i*4+3])+127)/255)
        })
    }
}
