import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct FontStudioTests {
    private func image() throws -> Data {
        let size = 48
        let bytes = Data((0..<(size*size)).flatMap { i -> [UInt8] in
            let dx = Double(i%size)-23.5,dy = Double(i/size)-23.5,radius = sqrt(dx*dx+dy*dy)
            let c: UInt8 = radius>8 && radius<19 ? 0:255
            return [c,c,c,255]
        })
        return try CutoutImageIO.png(.init(width: size,height: size,rgba: bytes))
    }
    private func fixture() async throws -> (URL,Project,URL) {
        let sourcePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-font-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic font",root: root,engine: sourcePath)
        return (root,project,sourcePath)
    }
    @Test func realTraceCompileAndReplacementKeepOldFontFilesAndSourcesImmutable() async throws {
        let (root,project,engine) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = FontStudioRepository(), compiler = FontCompilerService(), id = UUID(), raw = try image()
        var saved = try await repo.create(project,id: id,label: "Synthetic source font")
        let source = try await repo.importImage(project,fontID: id,id: UUID(),name: "O.png",bytes: raw)
        let mapping = try FontPendingMapping(sourceID: source.id,character: "O").request(source: source)
        let raster = try #require(await repo.rasterBytes(project,fontID: id,source: source))
        let rasterName = try #require(mapping.rasterFile)
        let trace = try await compiler.execute(action: "trace",request: FontCompilerRequest.data(mapping),inputs: [mapping.sourceFile:raw,rasterName:raster],project: project,engine: engine)
        let glyph = try FontGlyph.fromCompiler(#require(trace.files["glyph.json"]),sourceID: source.id)
        #expect(glyph.origin == .suppliedImage && glyph.outline.contours.count == 2)
        var draft = saved.draft; draft.sources.append(source); draft.glyphs.append(glyph)
        saved = try await repo.save(project,base: saved,draft: draft)
        let revisionID = UUID(), family = "Clauto Custom Synthetic "+String(revisionID.uuidString.prefix(8))
        let compiled = try await compiler.execute(action: "build",request: FontCompilerRequest.build(family: family,glyphs: saved.draft.glyphs),inputs: repo.compilationInputs(project,snapshot: saved),project: project,engine: engine)
        let expectedRequest = try FontCompilerRequest.build(family: family,glyphs: saved.draft.glyphs)
        let evidenceManifest = try JSONSerialization.jsonObject(with: #require(compiled.files["manifest.json"])) as! [String:Any]
        #expect(evidenceManifest["input_request_sha256"] as? String == TranscriptSourceMap.sha(expectedRequest))
        if let path = ProcessInfo.processInfo.environment["CLAUTO_FONT_SYNTHETIC_FAILURE_EVIDENCE"] {
            let folder = URL(fileURLWithPath: path,isDirectory: true);try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            try expectedRequest.write(to: folder.appendingPathComponent("native-request.json"),options: .withoutOverwriting)
            try compiled.files["manifest.json"]!.write(to: folder.appendingPathComponent("compiler-manifest.json"),options: .withoutOverwriting)
        }
        let revision = FontExportRevision(schemaVersion: 1,id: revisionID,fontID: id,projectID: project.id,parentRevisionID: nil,createdMilliseconds: 1000,family: family,draftSHA256: saved.savedSHA256,glyphsSHA256: TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(saved.draft.glyphs)),ttfSHA256: TranscriptSourceMap.sha(try #require(compiled.files["font.ttf"])),woff2SHA256: TranscriptSourceMap.sha(try #require(compiled.files["font.woff2"])),compilerSHA256: compiled.scriptSHA256,compilerDependenciesSHA256: compiled.dependenciesSHA256,engineVersion: compiled.engineVersion,licenseSHA256: nil)
        let result = try await repo.publish(project,snapshot: saved,revision: revision,compiled: compiled), oldFont = try Data(contentsOf: result.ttfURL)
        let woffBytes = try Data(contentsOf: result.woff2URL)
        #expect(oldFont.prefix(4) == Data([0,1,0,0]) && woffBytes.prefix(4) == Data("wOF2".utf8))
        #expect(try await repo.publish(project,snapshot: saved,revision: revision,compiled: compiled).revision == revision)
        saved = result.snapshot; draft = saved.draft
        draft.glyphs[0].outline.advance += 20; draft.glyphs[0].origin = .editedOutline; draft.glyphs[0].revisionID = UUID(); draft.glyphs[0].outlineSHA256 = try draft.glyphs[0].outline.sha256
        saved = try await repo.save(project,base: saved,draft: draft)
        #expect(saved.draft.glyphs[0].origin == .editedOutline)
        let retainedOriginal = try await repo.imageBytes(project,fontID: id,source: source)
        #expect(try Data(contentsOf: result.ttfURL) == oldFont && retainedOriginal == raw)
    }
    @Test func staleMappingAndTamperedOriginalCannotReplaceSavedSourceOrFont() async throws {
        let (root,project,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = FontStudioRepository(), id = UUID(), initial = try await repo.create(project,id: id,label: "Initial")
        let source = try await repo.importImage(project,fontID: id,id: UUID(),name: "O.png",bytes: image())
        var first = initial.draft; first.sources = [source]; first.label = "First correction"
        let current = try await repo.save(project,base: initial,draft: first)
        var stale = initial.draft; stale.label = "Other writer"
        await #expect(throws: (any Error).self) { _ = try await repo.save(project,base: initial,draft: stale) }
        #expect(try await repo.load(project,id: id) == current)
        let path = project.folder.appendingPathComponent("assets/generated-fonts/\(id)/sources/\(source.id)/original.image")
        try Data("changed".utf8).write(to: path)
        await #expect(throws: (any Error).self) { _ = try await repo.imageBytes(project,fontID: id,source: source) }
        #expect(try await repo.load(project,id: id).draft.currentFontRevisionID == nil)
    }
}
