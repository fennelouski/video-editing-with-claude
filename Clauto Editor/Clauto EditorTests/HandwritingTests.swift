import Foundation
import Testing
import AVFoundation
import CoreVideo
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@Suite(.serialized) struct HandwritingTests {
    private let renderer = HandwritingRenderer()
    /// A deliberately synthetic ink strip, with straight RGB at soft alpha edges.
    /// It tests masking mechanics and is never described as AI or user handwriting.
    private func ink() -> CutoutRaster {
        let width = 64,height = 40
        var bytes = [UInt8](repeating: 0,count: width*height*4)
        for y in 18...22 { for x in 12...51 {
            let i = (y*width+x)*4
            bytes[i] = 74;bytes[i+1] = 60;bytes[i+2] = 46
            bytes[i+3] = y == 18 || y == 22 ? 128:255
        } }
        return .init(width: width,height: height,rgba: Data(bytes))
    }
    private func recipe(start: Int = 0) -> HandwritingRecipe {
        .init(strokes: [.init(points: [.init(x: 12.0/63,y: 20.0/39),.init(x: 51.0/63,y: 20.0/39)],startFrame: start,durationFrames: 8,pauseAfterFrames: 2,easing: .linear,maskWidthPixels: 8)],frameCount: 12)
    }
    private func fixture(keepOutput: Bool = false) async throws -> (URL,Project) {
        let env = ProcessInfo.processInfo.environment["CLAUTO_HANDWRITING_QA_OUTPUT"]
        let base = keepOutput ? env.map { URL(fileURLWithPath: $0,isDirectory: true) } : nil
        let root = (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("clauto-handwriting-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (root,try await ProjectRepository().create(name: "Synthetic handwriting QA",root: root,engine: engine))
    }
    private func document(project: Project,original: Data,text: String = "Cre\u{300}me bru\u{302}le\u{301}e & <notes>") -> HandwritingDocument {
        var value = HandwritingDocument(projectID: project.id,exactText: text,locale: "fr-FR")
        value.provenance.kind = .fixture
        value.provenance.provider = "Synthetic test pixels; not AI or user artwork"
        value.provenance.sourceName = "synthetic-ink.png"
        value.provenance.sourceSHA256 = TranscriptSourceMap.sha(original)
        value.recipe = recipe()
        return value
    }
    private func approved(_ value: HandwritingDocument) -> HandwritingDocument {
        var next = value
        next.review = .init(status: .approved,liked: true,spellingChecked: true,alphaEdgesChecked: true,
                            reviewer: "Synthetic test reviewer (not a user approval)",comments: "Synthetic mask mechanics only; not a production style.",contexts: ["Automated test fixtures only"])
        return next
    }
    private func alpha(_ image: CutoutRaster,_ x: Int,_ y: Int) -> UInt8 { image.rgba[(y*image.width+x)*4+3] }

    @Test func exactUTF8LocaleAndDraftReviewSurviveSerializationWithoutApproval() throws {
        let original = try CutoutImageIO.png(ink())
        var value = HandwritingDocument(projectID: UUID(),exactText: "Cre\u{300}me bru\u{302}le\u{301}e\nالعَرَبِيَّة",locale: "fr-FR")
        value.provenance.sourceSHA256 = TranscriptSourceMap.sha(original)
        value.recipe = recipe()
        let bytes = try CreativeAssetFiles.encoder().encode(value)
        let decoded = try CreativeAssetFiles.decode(bytes,as: HandwritingDocument.self)
        #expect(Array(decoded.exactText.utf8) == Array(value.exactText.utf8))
        #expect(decoded.locale == "fr-FR" && decoded.review.status == .draft)
        #expect(!decoded.review.liked && !decoded.review.spellingChecked && !decoded.review.alphaEdgesChecked)
        var incomplete = value.review;incomplete.status = .approved
        #expect(throws: (any Error).self) { try incomplete.validate() }
        incomplete = .init(status: .rejected)
        #expect(throws: (any Error).self) { try incomplete.validate() }
        incomplete.comments = "Accent is missing; regenerate."
        try incomplete.validate()
        var reviewed = approved(value).review;reviewed.invalidateApproval()
        #expect(reviewed.status == .draft && !reviewed.spellingChecked && !reviewed.alphaEdgesChecked)
    }

    @Test func invalidTimingAndNonfiniteBrushInputsRefuseBeforeRendering() throws {
        var invalid = recipe();invalid.strokes[0].startFrame = 1
        #expect(throws: (any Error).self) { _ = try renderer.render(ink: ink(),recipe: invalid,frame: 0) }
        invalid = recipe();invalid.strokes[0].durationFrames = Int.max
        #expect(throws: (any Error).self) { try invalid.validate(width: 64,height: 40) }
        invalid = recipe();invalid.strokes[0].maskWidthPixels = .nan
        #expect(throws: (any Error).self) { try invalid.validate(width: 64,height: 40) }
        invalid = recipe();invalid.extraction.softness = .infinity
        #expect(throws: (any Error).self) { _ = try renderer.extract(source: ink(),recipe: invalid) }
        #expect(throws: (any Error).self) { _ = try renderer.render(ink: ink(),recipe: recipe(),frame: -1) }
        #expect(throws: (any Error).self) { _ = try renderer.render(ink: ink(),recipe: recipe(),frame: 12) }
    }

    @Test func sourceAlphaPaperKeyAndCleanupPreserveStraightEdges() throws {
        let source = ink(),sourceRecipe = recipe()
        #expect(try renderer.extract(source: source,recipe: sourceRecipe) == source)
        for dark in [false,true] {
            var opaque = [UInt8](repeating: dark ? 0:255,count: 64*40*4)
            for i in stride(from: 3,to: opaque.count,by: 4) { opaque[i] = 255 }
            for y in 18...22 { for x in 12...51 {
                let i = (y*64+x)*4,coverage = y == 18 || y == 22 ? 0.5:1.0
                let value = UInt8(((dark ? coverage:1-coverage)*255).rounded())
                opaque[i] = value;opaque[i+1] = value;opaque[i+2] = value
            } }
            var keyed = recipe();keyed.extraction.mode = dark ? .darkPaper:.lightPaper
            keyed.extraction.threshold = 0;keyed.extraction.softness = 1
            let output = try renderer.extract(source: .init(width: 64,height: 40,rgba: Data(opaque)),recipe: keyed)
            #expect(alpha(output,0,0) == 0 && alpha(output,30,20) == 255)
            #expect(abs(Int(alpha(output,30,18))-128)<=1)
            let edge = (18*64+30)*4
            #expect(output.rgba[edge] == 74 && output.rgba[edge+1] == 60 && output.rgba[edge+2] == 46)
        }
        var erased = sourceRecipe
        erased.extraction.cleanup = [.init(mode: .erase,radiusPixels: 4,points: [.init(x: 30.0/63,y: 20.0/39)])]
        let output = try renderer.extract(source: source,recipe: erased)
        #expect(alpha(output,30,20) == 0 && alpha(output,14,20) == 255)
        #expect(throws: (any Error).self) {
            _ = try renderer.extract(source: .init(width: 8,height: 8,rgba: Data(repeating: 255,count: 8*8*4)),recipe: .init())
        }
    }

    @Test func evenFrameMaskDirectionPauseOverlapAndMissedInkAreObservable() throws {
        let source = ink(),forward = recipe(start: 2)
        let early = try renderer.render(ink: source,recipe: forward,frame: 0)
        #expect(stride(from: 3,to: early.rgba.count,by: 4).allSatisfy { early.rgba[$0] == 0 })
        let progress = try renderer.render(ink: source,recipe: forward,frame: 4)
        #expect(progress == (try renderer.render(ink: source,recipe: forward,frame: 5)))
        #expect(alpha(progress,16,20) == 255 && alpha(progress,48,20) == 0)
        var backwards = forward;backwards.strokes[0].reverse = true
        let reversed = try renderer.render(ink: source,recipe: backwards,frame: 4)
        #expect(alpha(reversed,16,20) == 0 && alpha(reversed,48,20) == 255)
        #expect(try renderer.render(ink: source,recipe: forward,frame: 11) == source)
        var ordered = recipe();ordered.strokes.append(.init(points: [.init(x: 0.7,y: 0.5)],durationFrames: 6,pauseAfterFrames: 4))
        ordered.retimeInOrder(overlapFrames: 2)
        #expect(ordered.strokes[1].startFrame == 8)
        #expect(ordered.frameCount%2 == 0 && ordered.strokes.allSatisfy { $0.startFrame%2 == 0 })
        var missed = recipe();missed.strokes[0].points = [.init(x: 0.01,y: 0.01)]
        let quality = try renderer.quality(ink: source,recipe: missed)
        #expect(quality.unrevealedPixels > 0 && quality.coverage < 1)
        #expect(try renderer.render(ink: source,recipe: missed,frame: 11) != source)
    }

    @Test func graphSuggestionsAreDeterministicAndRetainDetachedInk() throws {
        var bytes = Array(ink().rgba)
        for y in 8...10 { for x in 28...30 {
            let i = (y*64+x)*4;bytes[i] = 74;bytes[i+1] = 60;bytes[i+2] = 46;bytes[i+3] = 255
        } }
        let source = CutoutRaster(width: 64,height: 40,rgba: Data(bytes))
        let paths = try renderer.suggestedStrokes(for: source,locale: "fr-FR")
        #expect(!paths.isEmpty && paths == (try renderer.suggestedStrokes(for: source,locale: "fr-FR")))
        #expect(paths.contains { $0.points.contains { $0.y < 0.35 } })
        var generated = HandwritingRecipe(strokes: paths);generated.retimeInOrder()
        try generated.validate(width: source.width,height: source.height)
        #expect(try renderer.quality(ink: source,recipe: generated).unrevealedPixels == 0)
    }

    @Test func precancelledExtractionAndMaskRenderingReturnNoPixels() async throws {
        let source = ink(),parameters = recipe()
        let extraction = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try HandwritingRenderer().extract(source: source,recipe: parameters)
        }
        await #expect(throws: CancellationError.self) { _ = try await extraction.value }
        let animation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try HandwritingRenderer().render(ink: source,recipe: parameters,frame: 4)
        }
        await #expect(throws: CancellationError.self) { _ = try await animation.value }
    }

    @Test func immutableRevisionsRejectChangedRetryAndOnlyExactApprovedStylesAreDiscoverable() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repository = HandwritingRepository(),original = try CutoutImageIO.png(ink())
        let draft = document(project: project,original: original)
        let folder = try await repository.save(project,document: draft,original: original)
        #expect(try await repository.save(project,document: draft,original: original) == folder)
        var collision = draft;collision.review.comments = "Different bytes at same revision are forbidden."
        await #expect(throws: (any Error).self) { _ = try await repository.save(project,document: collision,original: original) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("original.image")) == original)
        #expect(try await repository.approvedStyles(project).isEmpty)
        var accepted = approved(draft);accepted.parentRevisionID = draft.revisionID;accepted.revisionID = UUID()
        _ = try await repository.save(project,document: accepted,original: original)
        let preset = HandwritingStylePreset(name: "Synthetic short label",sourceRevisionID: accepted.revisionID,sourceAssetID: accepted.id,exactText: accepted.exactText,locale: accepted.locale,sourceWidth: 64,sourceHeight: 40,recipe: accepted.recipe,review: accepted.review,provenance: accepted.provenance)
        _ = try await repository.saveStyle(project,preset: preset)
        #expect(try await repository.approvedStyles(project) == [preset])
        var forged = preset;forged.id = UUID();forged.review.comments = "An unapproved replacement reason."
        await #expect(throws: (any Error).self) { _ = try await repository.saveStyle(project,preset: forged) }
        var rejected = accepted;rejected.parentRevisionID = accepted.revisionID;rejected.revisionID = UUID()
        rejected.review.status = .rejected;rejected.review.comments = "Synthetic regeneration test."
        _ = try await repository.save(project,document: rejected,original: original)
        #expect(try await repository.list(project).count == 3)
        let loaded = try await repository.load(project,assetID: draft.id,revisionID: draft.revisionID)
        #expect(loaded.0 == draft && loaded.1 == original)
        var uncovered = approved(draft);uncovered.id = UUID();uncovered.revisionID = UUID();uncovered.recipe.strokes = []
        await #expect(throws: (any Error).self) { _ = try await repository.save(project,document: uncovered,original: original) }
    }

    @Test func alphaMovieActuallyDecodesEveryExactTimestampAndXMLKeepsSeparateLayer() async throws {
        let keep = ProcessInfo.processInfo.environment["CLAUTO_HANDWRITING_QA_OUTPUT"] != nil
        let (root,project) = try await fixture(keepOutput: true)
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }
        let original = try CutoutImageIO.png(ink()),repository = HandwritingRepository()
        let value = approved(document(project: project,original: original))
        _ = try await repository.save(project,document: value,original: original)
        let result = try await HandwritingExportService().export(project,document: value,original: original)
        #expect(result.proof.decodedEveryFrame && result.proof.frameCount == value.recipe.frameCount)
        #expect(result.proof.codec == "ap4h" && result.proof.maximumEndpointAlphaError <= 2)
        #expect(result.proof.durationValue == Int64(value.recipe.frameCount)*1001 && result.proof.durationScale == 24000)
        let xml = try XMLDocument(contentsOf: result.timelineURL,options: [])
        let clip = try #require(xml.nodes(forXPath: "//asset-clip").first as? XMLElement)
        #expect(clip.attribute(forName: "name")?.stringValue == value.exactText)
        #expect(clip.attribute(forName: "lane")?.stringValue == "1")
        #expect(try xml.nodes(forXPath: "//format[@frameDuration='1001/24000s']").count == 1)
        let first = try CutoutImageIO.decode(Data(contentsOf: result.folderURL.appendingPathComponent("first.png"))).raster
        let final = try CutoutImageIO.decode(Data(contentsOf: result.folderURL.appendingPathComponent("final.png"))).raster
        #expect(first != final && final.width == 320 && final.height == 240)
        #expect(stride(from: 3,to: first.rgba.count,by: 4).allSatisfy { first.rgba[$0] == 0 })
        #expect(stride(from: 3,to: final.rgba.count,by: 4).contains { final.rgba[$0] == 128 })
        let asset = SourceMediaVerifier.asset(at: result.movieURL)
        let track = try #require(await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        try #require(reader.canAdd(output));reader.add(output);try #require(reader.startReading())
        var count = 0,hasClear = false,hasInk = false
        while let sample = output.copyNextSampleBuffer() {
            #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value: Int64(count)*1001,timescale: 24000)) == 0)
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample));CVPixelBufferLockBaseAddress(buffer,.readOnly)
            let pixels = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<CVPixelBufferGetHeight(buffer) { for x in 0..<CVPixelBufferGetWidth(buffer) {
                let alpha = pixels[y*row+x*4+3];hasClear = hasClear || alpha == 0;hasInk = hasInk || alpha >= 254
            } }
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly);count += 1
        }
        #expect(reader.status == .completed && count == 12 && hasClear && hasInk)
        #expect(FileManager.default.fileExists(atPath: result.folderURL.appendingPathComponent("COMPLETE.txt").path))
        let exportID = try #require(UUID(uuidString: result.folderURL.lastPathComponent))
        await #expect(throws: (any Error).self) { _ = try await HandwritingExportService().export(project,document: value,original: original,id: exportID) }
        var draft = value;draft.review.invalidateApproval()
        await #expect(throws: (any Error).self) { _ = try await HandwritingExportService().export(project,document: draft,original: original) }
    }

    @Test func optionalGeneratedArtworkProducesUnapprovedReviewFrames() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUTO_HANDWRITING_ARTWORK"],
              let output = ProcessInfo.processInfo.environment["CLAUTO_HANDWRITING_QA_OUTPUT"] else { return }
        let original = try Data(contentsOf: URL(fileURLWithPath: path)),source = try CutoutImageIO.decode(original).raster
        var value = HandwritingDocument(projectID: UUID(),exactText: "Crème brûlée",locale: "fr-FR")
        value.provenance.kind = .aiGenerated;value.provenance.provider = "OpenAI built-in image_gen"
        value.provenance.model = "Not exposed by built-in tool";value.provenance.requestID = URL(fileURLWithPath: path).lastPathComponent
        value.provenance.sourceName = URL(fileURLWithPath: path).lastPathComponent;value.provenance.sourceSHA256 = TranscriptSourceMap.sha(original)
        value.provenance.prompt = "Use case: scientific-educational. Asset type: isolated handwritten video label for Clauto handwriting workflow QA. Text (verbatim, French): \"Crème brûlée\". Preserve every letter, space, case and accent exactly: grave accent on è, circumflex on û, acute accent on é. Warm walnut charcoal felt-tip everyday cursive handwriting, readable medium strokes with natural joins and modest baseline variation. Wide compact one-line composition with ample empty margins. Genuine transparent alpha background, no paper or checkerboard baked into pixels. No pen, hand, scene, border, decorations, underlines, additional words or watermark. This is artwork generation, not a typeset font. No claim of recorded pen telemetry."
        let ink = try renderer.extract(source: source,recipe: value.recipe)
        value.recipe.strokes = try renderer.suggestedStrokes(for: ink,locale: value.locale)
        value.recipe.retimeInOrder()
        try value.validate(width: source.width,height: source.height)
        let folder = URL(fileURLWithPath: output,isDirectory: true).appendingPathComponent("generated-artwork-review-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        try original.write(to: folder.appendingPathComponent("original.png"),options: .withoutOverwriting)
        try CreativeAssetFiles.encoder().encode(value).write(to: folder.appendingPathComponent("unapproved-document.json"),options: .withoutOverwriting)
        let quality = try renderer.quality(ink: ink,recipe: value.recipe)
        try CreativeAssetFiles.encoder().encode(quality).write(to: folder.appendingPathComponent("quality.json"),options: .withoutOverwriting)
        for percent in [0,15,45,72,100] {
            let frame = min(value.recipe.frameCount-1,Int(Double(value.recipe.frameCount-1)*Double(percent)/100))
            let image = try renderer.render(ink: ink,recipe: value.recipe,frame: frame)
            try CutoutImageIO.png(image).write(to: folder.appendingPathComponent("reveal-\(percent).png"),options: .withoutOverwriting)
        }
        #expect(value.review.status == .draft && !value.review.liked && !value.review.spellingChecked && !value.review.alphaEdgesChecked)
        #expect(quality.inkPixels > 0 && quality.partialAlphaPixels > 0 && quality.boundaryInkPixels == 0)
    }
}
