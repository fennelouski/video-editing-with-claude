import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct CutoutWorkflowTests {
    private func source(width: Int = 8,height: Int = 6) -> CutoutRaster {
        var pixels: [UInt8] = []
        for y in 0..<height { for x in 0..<width { pixels += [UInt8(x*20),UInt8(y*30),90,255] } }
        return .init(width: width,height: height,rgba: Data(pixels))
    }
    private func mask(width: Int = 8,height: Int = 6,xs: ClosedRange<Int>,ys: ClosedRange<Int>) -> Data {
        Data((0..<(width*height)).map { xs.contains($0%width) && ys.contains($0/width) ? 255:0 })
    }
    @Test func selectingOneSubjectRetainsSourceColorsAndOnlyItsAlpha() throws {
        let image = source(), chosen = mask(xs: 5...6,ys: 2...3)
        let detection = CutoutDetection(width: 8,height: 6,subjects: [.init(id: 1,mask: mask(xs: 1...2,ys: 1...4)),.init(id: 2,mask: chosen)],model: "Synthetic masks",modelRevision: 1)
        var recipe = CutoutRecipe(); recipe.selectedSubjects = [2]
        let output = try CutoutMaskProcessor().render(image,recipe: recipe,detection: detection)
        let raw = Array(image.rgba), result = Array(output.image.rgba)
        #expect(output.foregroundPixels == 4 && output.mask == chosen)
        for i in 0..<48 {
            #expect(Array(result[i*4..<(i*4+3)]) == Array(raw[i*4..<(i*4+3)]))
            #expect(result[i*4+3] == chosen[i])
        }
        #expect(output.sourceRasterSHA256 == TranscriptSourceMap.sha(image.rgba))
        recipe.selectedSubjects = [99]
        #expect(throws: CutoutFailure.self) { _ = try CutoutMaskProcessor().render(image,recipe: recipe,detection: detection) }
    }
    @Test func restoreEraseAndFeatherChangeOnlyMaskPixelsInOrientedCoordinates() throws {
        let image = source(); var recipe = CutoutRecipe()
        recipe.strokes = [.init(mode: .restore,radiusPixels: 1,points: [.init(x: 0.5,y: 0.5)]),
                          .init(mode: .erase,radiusPixels: 0.5,points: [.init(x: 3.5/8,y: 2.5/6)])]
        let sharp = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil)
        #expect(sharp.foregroundPixels == 3 && sharp.mask[2*8+3] == 0 && sharp.mask[3*8+4] == 255)
        recipe.featherPixels = 1
        let soft = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil)
        #expect(soft.mask.contains { $0 > 0 && $0 < 255 } && soft.mask.contains(0))
        for i in 0..<48 { #expect(soft.image.rgba[i*4] == image.rgba[i*4]) }
    }
    @Test func manualMaskHashEmptyFullAndInvisibleFeatherAreRefused() throws {
        let image = source(), pixels = mask(xs: 2...3,ys: 2...3)
        var recipe = CutoutRecipe()
        #expect(throws: CutoutFailure.self) { _ = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil,manualMask: pixels) }
        recipe.manualMaskSHA256 = TranscriptSourceMap.sha(pixels)
        #expect(try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil,manualMask: pixels).foregroundPixels == 4)
        for value in [UInt8(0),UInt8(255)] {
            let invalid = Data(repeating: value,count: 48); recipe.manualMaskSHA256 = TranscriptSourceMap.sha(invalid)
            #expect(throws: CutoutFailure.self) { _ = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil,manualMask: invalid) }
        }
        let dot = mask(xs: 3...3,ys: 2...2); recipe.manualMaskSHA256 = TranscriptSourceMap.sha(dot); recipe.featherPixels = 16
        #expect(throws: CutoutFailure.self) { _ = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil,manualMask: dot) }
    }
    @Test func actualPNGPreservesDimensionsOpaqueColorsAndTransparentBackground() throws {
        let original = source(), before = try CutoutImageIO.png(original)
        let decoded = try CutoutImageIO.decode(before)
        #expect(decoded.raster == original && decoded.originalSHA256 == TranscriptSourceMap.sha(before))
        var recipe = CutoutRecipe(); let selected = mask(xs: 2...3,ys: 2...3); recipe.manualMaskSHA256 = TranscriptSourceMap.sha(selected)
        let result = try CutoutMaskProcessor().render(original,recipe: recipe,detection: nil,manualMask: selected)
        let encoded = try CutoutImageIO.png(result.image), reopened = try CutoutImageIO.decode(encoded).raster
        #expect(reopened.width == 8 && reopened.height == 6 && reopened.rgba[3] == 0)
        for i in 0..<48 where selected[i] == 255 { #expect(Array(reopened.rgba[i*4..<(i*4+4)]) == Array(original.rgba[i*4..<(i*4+4)])) }
        #expect(try CutoutImageIO.png(original) == before)
    }
    @Test func EXIFOrientationIsAppliedOnceBeforeMaskCoordinates() throws {
        let image = source(), encoded = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(encoded,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(writer,try CutoutImageIO.image(image),[kCGImagePropertyOrientation:6] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        let decoded = try CutoutImageIO.decode(encoded as Data)
        #expect(decoded.orientation == 6 && decoded.raster.width == 6 && decoded.raster.height == 8)
        #expect(Array(decoded.raster.rgba.prefix(4)) == [0,150,90,255])
    }
    @Test func cancellationAndMalformedCoordinatesCannotProduceACompletedRaster() throws {
        let image = source(); var recipe = CutoutRecipe()
        recipe.strokes = [.init(mode: .restore,radiusPixels: 2,points: [.init(x: 0.4,y: 0.4)])]
        #expect(throws: CancellationError.self) { _ = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil,checkCancellation: { throw CancellationError() }) }
        recipe.strokes[0].points[0].x = .nan
        #expect(throws: CutoutFailure.self) { _ = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil) }
        recipe.strokes[0].points[0].x = 1.1
        #expect(throws: CutoutFailure.self) { _ = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil) }
    }
    private func project() async throws -> (URL,Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-cutout-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let engine = root.appendingPathComponent("engine"); try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: true)
        return (root,try await ProjectRepository().create(name: "Synthetic cutouts",root: root,engine: engine))
    }
    @Test func originalReopenMaskCorrectionAndImmutablePNGRetainEveryRevision() async throws {
        let (root,project) = try await project(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = CutoutRepository(), id = UUID(), original = try CutoutImageIO.png(source())
        var saved = try await repo.create(project,id: id,createdMilliseconds: 123456,name: "Synthetic source.png",bytes: original)
        let initial = saved
        #expect(try await repo.list(project).map(\.id) == [id])
        saved = try await repo.create(project,id: id,createdMilliseconds: 123456,name: "Synthetic source.png",bytes: original)
        #expect(saved == initial)
        var draft = saved.draft; draft.recipe.strokes = [.init(mode: .restore,radiusPixels: 1,points: [.init(x: 0.5,y: 0.5)])]
        saved = try await repo.save(project,base: saved,draft: draft)
        let preview = try await repo.preview(project,snapshot: saved), firstID = UUID(), time = Date(timeIntervalSince1970: 1700000000)
        let first = try await repo.export(project,snapshot: saved,id: firstID,created: time), firstBytes = try Data(contentsOf: first.pngURL)
        let decodedPNG = try CutoutImageIO.decode(firstBytes).raster
        for i in 0..<48 {
            #expect(decodedPNG.rgba[i*4+3] == preview.image.rgba[i*4+3])
            if preview.image.rgba[i*4+3] == 255 {
                #expect(Array(decodedPNG.rgba[i*4..<(i*4+3)]) == Array(preview.image.rgba[i*4..<(i*4+3)]))
            }
        }
        // The ImageIO working decode premultiplies then unpremultiplies. RGB in
        // fully transparent pixels is unobservable; originals and the mask
        // processor retain those source bytes separately.
        #expect(try await repo.export(project,snapshot: saved,id: firstID,created: time).revision == first.revision)
        let reopened = CutoutRepository(); saved = try await reopened.load(project,id: id)
        #expect(saved.draft.currentRevisionID == firstID)
        draft = saved.draft; draft.recipe.featherPixels = 1
        saved = try await reopened.save(project,base: saved,draft: draft)
        let second = try await reopened.export(project,snapshot: saved,id: UUID(),created: time.addingTimeInterval(1))
        #expect(second.revision.parentRevisionID == firstID && second.pngURL != first.pngURL)
        #expect(try Data(contentsOf: first.pngURL) == firstBytes)
        let originalURL = project.folder.appendingPathComponent("assets/generated-cutouts/\(id)/original.image")
        #expect(try Data(contentsOf: originalURL) == original)
        #expect(second.revision.sourceSHA256 == TranscriptSourceMap.sha(original))
    }
    @Test func exactDraftCASAndSourceReplacementNeverOverwriteAnotherCorrection() async throws {
        let (root,project) = try await project(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = CutoutRepository(), other = CutoutRepository(), id = UUID(), bytes = try CutoutImageIO.png(source())
        let initial = try await repo.create(project,id: id,createdMilliseconds: 10,name: "Original",bytes: bytes)
        var first = initial.draft; first.recipe.featherPixels = 2
        let accepted = try await repo.save(project,base: initial,draft: first)
        var late = initial.draft; late.recipe.featherPixels = 7
        await #expect(throws: CutoutFailure.self) { _ = try await other.save(project,base: initial,draft: late) }
        #expect(try await other.load(project,id: id) == accepted)
        var changed = source(); changed = .init(width: changed.width,height: changed.height,rgba: Data(repeating: 255,count: changed.rgba.count))
        await #expect(throws: (any Error).self) { _ = try await other.create(project,id: id,createdMilliseconds: 10,name: "Original",bytes: CutoutImageIO.png(changed)) }
        #expect(try await repo.load(project,id: id) == accepted)
    }
    @Test func selectedAndSuppliedMasksAreSourceBoundAndCannotMasqueradeAsEachOther() async throws {
        let (root,project) = try await project(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = CutoutRepository(), id = UUID()
        var saved = try await repo.create(project,id: id,createdMilliseconds: 10,name: "Image",bytes: CutoutImageIO.png(source()))
        let detection = CutoutDetection(width: 8,height: 6,subjects: [.init(id: 1,mask: mask(xs: 2...3,ys: 2...3))],model: "Synthetic local masks",modelRevision: 1)
        let basis = try await repo.storeDetection(project,snapshot: saved,id: UUID(),detection: detection)
        var draft = saved.draft; draft.basisID = basis.id; draft.recipe.selectedSubjects = [1]
        saved = try await repo.save(project,base: saved,draft: draft)
        #expect(try await repo.preview(project,snapshot: saved).foregroundPixels == 4)
        let maskPNG = try CutoutImageIO.maskPNG(mask(xs: 4...5,ys: 1...2),width: 8,height: 6)
        let manual = try await repo.storeManualMask(project,snapshot: saved,id: UUID(),encodedMask: maskPNG)
        draft = saved.draft; draft.basisID = manual.id; draft.recipe.manualMaskSHA256 = manual.manualSHA256
        await #expect(throws: CutoutFailure.self) { _ = try await repo.save(project,base: saved,draft: draft) }
        draft.recipe.selectedSubjects = []; saved = try await repo.save(project,base: saved,draft: draft)
        #expect(try await CutoutRepository().preview(project,snapshot: saved).foregroundPixels == 4)
    }

    @Test func syntheticRenderedMaskKeepsAClearCounterAndFeatheredEdges() throws {
        let width = 64, height = 64
        let rgba = Data((0..<(width*height)).flatMap { i -> [UInt8] in [UInt8(80+i%width*2),UInt8(30+i/width*2),190,255] })
        let image = CutoutRaster(width: width,height: height,rgba: rgba)
        var recipe = CutoutRecipe(); recipe.featherPixels = 2
        recipe.strokes = [.init(mode: .restore,radiusPixels: 22,points: [.init(x: 0.5,y: 0.5)]),
                          .init(mode: .erase,radiusPixels: 9,points: [.init(x: 0.5,y: 0.5)])]
        let output = try CutoutMaskProcessor().render(image,recipe: recipe,detection: nil)
        let center = 32*width+32, ring = 32*width+48
        #expect(output.image.rgba[center*4+3] == 0 && output.image.rgba[ring*4+3] == 255)
        #expect(output.mask.contains { $0 > 0 && $0 < 255 })
        let png = try CutoutImageIO.png(output.image), decoded = try CutoutImageIO.decode(png)
        #expect(decoded.raster.width == width && decoded.raster.height == height)
        #expect(decoded.raster.rgba[center*4+3] == 0 && decoded.raster.rgba[ring*4+3] == 255)
        if let path = ProcessInfo.processInfo.environment["CLAUTO_CUTOUT_SYNTHETIC_OUTPUT"] {
            let destination = URL(fileURLWithPath: path,isDirectory: true)
            try FileManager.default.createDirectory(at: destination,withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("cutout-alpha.png"),options: .withoutOverwriting)
            try CutoutImageIO.png(image).write(to: destination.appendingPathComponent("original.png"),options: .withoutOverwriting)
            try CutoutImageIO.maskPNG(output.mask,width: width,height: height).write(to: destination.appendingPathComponent("mask.png"),options: .withoutOverwriting)
        }
    }
    @Test func tamperedOriginalAndSymlinkedMaskDirectoryCannotGenerateAnOutput() async throws {
        let (root,project) = try await project(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = CutoutRepository(), id = UUID(), original = try CutoutImageIO.png(source())
        let saved = try await repo.create(project,id: id,createdMilliseconds: 123,name: "Synthetic",bytes: original)
        let asset = project.folder.appendingPathComponent("assets/generated-cutouts/\(id)")
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside,withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: asset.appendingPathComponent("mask-bases"),withDestinationURL: outside)
        let detection = CutoutDetection(width: 8,height: 6,subjects: [.init(id: 1,mask: mask(xs: 2...3,ys: 2...3))],model: "Synthetic",modelRevision: 1)
        await #expect(throws: (any Error).self) { _ = try await repo.storeDetection(project,snapshot: saved,id: UUID(),detection: detection) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try Data("tampered".utf8).write(to: asset.appendingPathComponent("original.image"))
        await #expect(throws: (any Error).self) { _ = try await repo.source(project,id: id) }
        await #expect(throws: (any Error).self) { _ = try await repo.export(project,snapshot: saved,id: UUID(),created: Date()) }
        #expect(try await repo.load(project,id: id).draft.currentRevisionID == nil)
    }

}
