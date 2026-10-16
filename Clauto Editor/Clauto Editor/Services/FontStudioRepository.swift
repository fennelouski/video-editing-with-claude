import Foundation
import CoreGraphics

struct FontExportRevision: Codable,Equatable,Identifiable,Sendable {
    let schemaVersion: Int
    let id: UUID
    let fontID: UUID
    let projectID: UUID
    let parentRevisionID: UUID?
    let createdMilliseconds: Int64
    let family: String
    let draftSHA256: String
    let glyphsSHA256: String
    let ttfSHA256: String
    let woff2SHA256: String
    let compilerSHA256: String
    let compilerDependenciesSHA256: [String:String]
    let engineVersion: String
    let licenseSHA256: String?
}
struct FontExportResult: Sendable {
    let revision: FontExportRevision
    let snapshot: FontDraftSnapshot
    let ttfURL: URL
    let woff2URL: URL
}
private struct FontCompileManifest: Decodable {
    let schemaVersion: Int
    let family: String
    let glyphs: [Entry]
    let ttfSHA256: String
    let woff2SHA256: String
    let requestSHA256: String
    let inputRequestSHA256: String
    enum CodingKeys: String,CodingKey { case family,glyphs;case schemaVersion = "schema_version",ttfSHA256 = "ttf_sha256",woff2SHA256 = "woff2_sha256",requestSHA256 = "request_sha256",inputRequestSHA256 = "input_request_sha256" }
    struct Entry: Decodable {
        let scalar: Int
        let origin: FontGlyphOrigin
        let sourceSHA256: String
        let outlineSHA256: String
        let licenseSHA256: String?
        let rasterSHA256: String?
        enum CodingKeys: String,CodingKey { case scalar,origin;case sourceSHA256 = "source_sha256",outlineSHA256 = "outline_sha256",licenseSHA256 = "license_sha256",rasterSHA256 = "raster_sha256" }
    }
}

actor FontStudioRepository {
    private let inputByteLimit: Int
    init(inputByteLimit: Int = 512*1024*1024) { self.inputByteLimit = max(1,min(512*1024*1024,inputByteLimit)) }
    private func remaining(_ consumed: Int,limit: Int? = nil) throws -> Int {
        let bytes = (limit ?? inputByteLimit)-consumed
        guard bytes>0 else { throw WorkflowFailure.invalid("This font exceeds its local source byte budget. Its previous saved font remains available.") };return bytes
    }
    private struct Index: Codable { var schemaVersion = 1; let projectID: UUID; var fontIDs: [UUID] }
    private func index(_ state: SourceRenderDirectory,project: UUID) throws -> Index {
        guard try CreativeAssetFiles.exists("font-index.json",in: state) else { return .init(projectID: project,fontIDs: []) }
        let value = try CreativeAssetFiles.decode(state.read("font-index.json",limit: 65536),as: Index.self)
        guard value.schemaVersion == 1,value.projectID == project,value.fontIDs.count <= 512,Set(value.fontIDs).count == value.fontIDs.count else { throw ProjectFailure.invalidProject }; return value
    }
    private func encodeDraft(_ draft: FontStudioDraft) throws -> Data {
        try draft.validate();let bytes = try CreativeAssetFiles.encoder().encode(draft)
        guard bytes.count<=16*1024*1024 else { throw WorkflowFailure.invalid("This font's editable data exceeds 16 MiB. Its previous saved revision is preserved.") };return bytes
    }
    private func fonts(_ lease: ProjectMutationLease) throws -> SourceRenderDirectory { try lease.root.child("assets",create: true).child("generated-fonts",create: true) }
    private func read(_ folder: SourceRenderDirectory,project: UUID,id: UUID) throws -> FontDraftSnapshot {
        let bytes = try folder.read("draft.json",limit: 16*1024*1024), draft = try CreativeAssetFiles.decode(bytes,as: FontStudioDraft.self)
        try draft.validate(); guard draft.projectID == project,draft.id == id else { throw ProjectFailure.invalidProject }
        return .init(draft: draft,savedSHA256: TranscriptSourceMap.sha(bytes))
    }
    func list(_ project: Project) throws -> [FontWorkspaceSummary] {
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let state = try lease.root.child(".clauto"),parent = try fonts(lease)
        return try index(state,project: project.id).fontIDs.map {
            let draft = try read(parent.child($0.uuidString),project: project.id,id: $0).draft
            return .init(id: draft.id,label: draft.label,glyphCount: draft.glyphs.count)
        }
    }
    func create(_ project: Project,id: UUID,label: String) throws -> FontDraftSnapshot {
        let value = FontStudioDraft(id: id,projectID: project.id,generation: 0,label: label,sources: [],glyphs: [])
        try value.validate(); let bytes = try encodeDraft(value)
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let state = try lease.root.child(".clauto"),parent = try fonts(lease); var catalog = try index(state,project: project.id)
        guard catalog.fontIDs.contains(id) || catalog.fontIDs.count < 512 else { throw WorkflowFailure.invalid("This project has 512 font workspaces. Create another project to continue.") }
        let folder = try CreativeAssetFiles.publish(["origin.json":try CreativeAssetFiles.encoder().encode(["fontID":id.uuidString,"projectID":project.id.uuidString])],to: id,in: parent)
        if !(try CreativeAssetFiles.exists("draft.json",in: folder)) { try folder.replacePointer(bytes,name: "draft.json") }
        if !catalog.fontIDs.contains(id) { catalog.fontIDs.append(id); try state.replacePointer(CreativeAssetFiles.encoder().encode(catalog),name: "font-index.json") }
        return try read(folder,project: project.id,id: id)
    }
    func load(_ project: Project,id: UUID) throws -> FontDraftSnapshot {
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        return try read(fonts(lease).child(id.uuidString),project: project.id,id: id)
    }
    func importImage(_ project: Project,fontID: UUID,id: UUID,name: String,bytes: Data) throws -> FontStudioSource {
        let decoded = try CutoutImageIO.decode(bytes)
        let raster = try CutoutImageIO.png(decoded.raster)
        let source = FontStudioSource(id: id,name: name,sha256: decoded.originalSHA256,width: decoded.raster.width,height: decoded.raster.height,orientation: decoded.orientation,workingRasterSHA256: TranscriptSourceMap.sha(raster))
        try source.validate()
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let folder = try fonts(lease).child(fontID.uuidString)
        _ = try read(folder,project: project.id,id: fontID)
        _ = try CreativeAssetFiles.publish(["original.image":bytes,"working-raster.image":raster,"source.json":try CreativeAssetFiles.encoder().encode(source)],to: id,in: folder.child("sources",create: true))
        try lease.validate(project); return source
    }
    private func imageBytes(_ font: SourceRenderDirectory,source: FontStudioSource,limit: Int = CutoutImageIO.sourceLimit) throws -> Data {
        let folder = try font.child("sources").child(source.id.uuidString)
        guard try CreativeAssetFiles.decode(folder.read("source.json",limit: 8192),as: FontStudioSource.self) == source else { throw CutoutFailure.changedSource }
        let bytes = try folder.read("original.image",limit: min(limit,CutoutImageIO.sourceLimit)), decoded = try CutoutImageIO.decode(bytes)
        guard decoded.originalSHA256 == source.sha256,decoded.orientation == source.orientation,
              decoded.raster.width == source.width,decoded.raster.height == source.height else { throw CutoutFailure.changedSource }; return bytes
    }
    func imageBytes(_ project: Project,fontID: UUID,source: FontStudioSource) throws -> Data {
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        return try imageBytes(fonts(lease).child(fontID.uuidString),source: source)
    }
    private func rasterBytes(_ font: SourceRenderDirectory,source: FontStudioSource,limit: Int = 256*1024*1024) throws -> Data? {
        guard let hash = source.workingRasterSHA256 else { return nil }
        let folder = try font.child("sources").child(source.id.uuidString)
        let bytes = try folder.read("working-raster.image",limit: min(limit,256*1024*1024)),decoded = try CutoutImageIO.decode(bytes,encodedLimit: 256*1024*1024)
        guard CutoutSourceInfo.validHash(hash),TranscriptSourceMap.sha(bytes)==hash,decoded.raster.width==source.width,decoded.raster.height==source.height,decoded.orientation==1 else { throw CutoutFailure.changedSource };return bytes
    }
    func rasterBytes(_ project: Project,fontID: UUID,source: FontStudioSource) throws -> Data? {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let font = try fonts(lease).child(fontID.uuidString);_ = try imageBytes(font,source: source);return try rasterBytes(font,source: source)
    }
    func previewRaster(_ project: Project,fontID: UUID,source: FontStudioSource) throws -> CutoutRaster {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let font = try fonts(lease).child(fontID.uuidString),original = try imageBytes(font,source: source)
        return try CutoutImageIO.decode(rasterBytes(font,source: source) ?? original,encodedLimit: 256*1024*1024).raster
    }
    private func hashUUID(_ hash: String) throws -> UUID {
        guard CutoutSourceInfo.validHash(hash) else { throw ProjectFailure.invalidProject }
        let p = Array(hash.prefix(32)); let value = String(p[0..<8])+"-"+String(p[8..<12])+"-"+String(p[12..<16])+"-"+String(p[16..<20])+"-"+String(p[20..<32])
        guard let id = UUID(uuidString: value) else { throw ProjectFailure.invalidProject }; return id
    }
    func retainFallback(_ project: Project,fontID: UUID,font: Data,license: Data) throws -> (fontSHA256: String,licenseSHA256: String) {
        guard font.count <= 16*1024*1024,license.count <= 65536,
              String(data: license,encoding: .utf8)?.contains("SIL OPEN FONT LICENSE") == true else { throw ProjectFailure.invalidProject }
        let hash = TranscriptSourceMap.sha(font), lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let folder = try fonts(lease).child(fontID.uuidString); _ = try read(folder,project: project.id,id: fontID)
        _ = try CreativeAssetFiles.publish(["fallback.ttf":font,"fallback-license.txt":license],to: hashUUID(hash),in: folder.child("licensed-sources",create: true))
        return (hash,TranscriptSourceMap.sha(license))
    }
    private func inputs(_ font: SourceRenderDirectory,draft: FontStudioDraft,byteLimit: Int? = nil) throws -> [String:Data] {
        var result: [String:Data] = [:],hashes: [String:String] = [:],consumed = 0
        func collect(_ name: String,hash: String,read: (Int) throws -> Data) throws {
            if let previous = hashes[name] { guard previous==hash else { throw CutoutFailure.changedSource };return }
            let available = try remaining(consumed,limit: byteLimit)
            // SourceRenderDirectory checks the file size before allocating or
            // reading it. The dictionary never exceeds the shared job budget.
            let bytes = try read(available)
            guard bytes.count<=available,TranscriptSourceMap.sha(bytes)==hash else { throw CutoutFailure.changedSource }
            result[name] = bytes;hashes[name] = hash;consumed += bytes.count
        }
        for glyph in draft.glyphs {
            if let sourceID = glyph.sourceID {
                guard let source = draft.sources.first(where: { $0.id == sourceID }) else { throw CutoutFailure.changedSource }
                try collect(glyph.sourceFile,hash: source.sha256) { try imageBytes(font,source: source,limit: $0) }
                if let rasterFile = glyph.rasterFile,let hash = glyph.rasterSHA256 {
                    try collect(rasterFile,hash: hash) { limit in guard let bytes = try rasterBytes(font,source: source,limit: limit) else { throw CutoutFailure.changedSource };return bytes }
                }
            } else {
                let folder = try font.child("licensed-sources").child(hashUUID(glyph.sourceSHA256).uuidString)
                guard let license = glyph.licenseSHA256 else { throw CutoutFailure.changedSource }
                try collect("fallback.ttf",hash: glyph.sourceSHA256) { try folder.read("fallback.ttf",limit: min($0,16*1024*1024)) }
                try collect("fallback-license.txt",hash: license) { try folder.read("fallback-license.txt",limit: min($0,65536)) }
            }
        }
        return result
    }
    func compilationInputs(_ project: Project,snapshot: FontDraftSnapshot) throws -> [String:Data] {
        try snapshot.draft.validate()
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let folder = try fonts(lease).child(snapshot.draft.id.uuidString)
        guard try read(folder,project: project.id,id: snapshot.draft.id).savedSHA256 == snapshot.savedSHA256 else { throw WorkflowFailure.invalid("This font changed in another window. Keep your current mapping before compiling.") }
        return try inputs(folder,draft: snapshot.draft)
    }
    func save(_ project: Project,base: FontDraftSnapshot,draft: FontStudioDraft) throws -> FontDraftSnapshot {
        try draft.validate()
        guard draft.id == base.draft.id,draft.projectID == project.id,draft.generation == base.draft.generation,
              draft.currentFontRevisionID == base.draft.currentFontRevisionID else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let folder = try fonts(lease).child(draft.id.uuidString), current = try read(folder,project: project.id,id: draft.id)
        var next = draft; next.generation += 1; try next.validate()
        if current.draft == next { return current }
        guard current.savedSHA256 == base.savedSHA256 else { throw WorkflowFailure.invalid("This font changed in another window. Your local outlines remain available to save as a separate font.") }
        // Validate every newly referenced source before publishing its mapping.
        for source in next.sources { _ = try imageBytes(folder,source: source) }
        _ = try inputs(folder,draft: next)
        try lease.validate(project); try folder.checkPath(); try folder.replacePointer(encodeDraft(next),name: "draft.json")
        return try read(folder,project: project.id,id: draft.id)
    }
    func copyDraft(_ project: Project,snapshot: FontDraftSnapshot,draft: FontStudioDraft,newID: UUID) throws -> FontDraftSnapshot {
        try draft.validate()
        guard draft.id == snapshot.draft.id,draft.projectID == project.id else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let parent = try fonts(lease),original = try parent.child(draft.id.uuidString),state = try lease.root.child(".clauto")
        // Verify exactly the source bytes copied below, before indexing a new font.
        var originals: [(FontStudioSource,Data,Data?)] = [],consumed = 0
        for source in draft.sources {
            let bytes = try imageBytes(original,source: source,limit: remaining(consumed));consumed += bytes.count
            let raster: Data?
            if source.workingRasterSHA256 != nil { raster = try rasterBytes(original,source: source,limit: remaining(consumed));consumed += raster?.count ?? 0 } else { raster = nil }
            originals.append((source,bytes,raster))
        }
        var fallbackOnly = draft;fallbackOnly.glyphs.removeAll { $0.sourceID != nil }
        let licenses = try inputs(original,draft: fallbackOnly,byteLimit: inputByteLimit-consumed)
        var catalog = try index(state,project: project.id)
        guard catalog.fontIDs.contains(newID) || catalog.fontIDs.count<512 else { throw ProjectFailure.invalidProject }
        let captured = try CreativeAssetFiles.encoder().encode(draft)
        let origin = ["fontID":newID.uuidString,"projectID":project.id.uuidString,"copiedFrom":draft.id.uuidString,"capturedDraftSHA256":TranscriptSourceMap.sha(captured)]
        let folder = try CreativeAssetFiles.publish(["origin.json":try CreativeAssetFiles.encoder().encode(origin)],to: newID,in: parent)
        for (source,bytes,raster) in originals {
            var sourceFiles = ["original.image":bytes,"source.json":try CreativeAssetFiles.encoder().encode(source)]
            if let raster { sourceFiles["working-raster.image"] = raster }
            _ = try CreativeAssetFiles.publish(sourceFiles,to: source.id,in: folder.child("sources",create: true))
        }
        if let font = licenses["fallback.ttf"],let license = licenses["fallback-license.txt"] {
            _ = try CreativeAssetFiles.publish(["fallback.ttf":font,"fallback-license.txt":license],to: hashUUID(TranscriptSourceMap.sha(font)),in: folder.child("licensed-sources",create: true))
        }
        let copy = FontStudioDraft(id: newID,projectID: project.id,generation: 0,label: draft.label,sources: draft.sources,glyphs: draft.glyphs,pendingMappings: draft.pendingMappings,currentFontRevisionID: nil)
        let bytes = try encodeDraft(copy)
        if try CreativeAssetFiles.exists("draft.json",in: folder) {
            guard try folder.read("draft.json",limit: 16*1024*1024)==bytes else { throw WorkflowFailure.invalid("The recovered font already has another saved correction. Create a separate copy to preserve both.") }
        } else { try folder.replacePointer(bytes,name: "draft.json") }
        if !catalog.fontIDs.contains(newID) { catalog.fontIDs.append(newID);try state.replacePointer(CreativeAssetFiles.encoder().encode(catalog),name: "font-index.json") }
        try lease.validate(project);return try read(folder,project: project.id,id: newID)
    }
    func revisions(_ project: Project,fontID: UUID) throws -> [FontExportRevision] {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let font = try fonts(lease).child(fontID.uuidString),snapshot = try read(font,project: project.id,id: fontID)
        var next = snapshot.draft.currentFontRevisionID,seen: Set<UUID> = [],result: [FontExportRevision] = []
        while let id = next {
            try Task.checkCancellation()
            guard seen.insert(id).inserted,result.count<1024 else { throw ProjectFailure.invalidProject }
            let revision = try CreativeAssetFiles.decode(font.child("revisions").child(id.uuidString).read("revision.json",limit: 65536),as: FontExportRevision.self)
            guard revision.id==id,revision.fontID==fontID,revision.projectID==project.id,revision.schemaVersion==1 else { throw ProjectFailure.invalidProject }
            result.append(revision);next = revision.parentRevisionID
        }
        return result
    }
    func fontBytes(_ project: Project,fontID: UUID,revisionID: UUID) throws -> (bytes: Data,ttfURL: URL,woff2URL: URL) {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let folder = try fonts(lease).child(fontID.uuidString).child("revisions").child(revisionID.uuidString)
        let revision = try CreativeAssetFiles.decode(folder.read("revision.json",limit: 65536),as: FontExportRevision.self)
        let ttf = try folder.read("font.ttf",limit: 32*1024*1024),woff = try folder.read("font.woff2",limit: 32*1024*1024)
        guard revision.id==revisionID,revision.fontID==fontID,revision.projectID==project.id,revision.schemaVersion==1,
              TranscriptSourceMap.sha(ttf)==revision.ttfSHA256,TranscriptSourceMap.sha(woff)==revision.woff2SHA256 else { throw CutoutFailure.changedSource }
        return (ttf,folder.url.appendingPathComponent("font.ttf"),folder.url.appendingPathComponent("font.woff2"))
    }
    func publish(_ project: Project,snapshot: FontDraftSnapshot,revision: FontExportRevision,compiled: FontCompilerFiles) throws -> FontExportResult {
        try snapshot.draft.validate()
        guard revision.schemaVersion == 1,revision.fontID == snapshot.draft.id,revision.projectID == project.id,
              revision.draftSHA256 == snapshot.savedSHA256,revision.compilerSHA256 == compiled.scriptSHA256,
              revision.engineVersion == compiled.engineVersion,revision.compilerDependenciesSHA256 == compiled.dependenciesSHA256,
              let ttf = compiled.files["font.ttf"],let woff = compiled.files["font.woff2"],let manifest = compiled.files["manifest.json"],
              TranscriptSourceMap.sha(ttf) == revision.ttfSHA256,TranscriptSourceMap.sha(woff) == revision.woff2SHA256,
              ttf.prefix(4) == Data([0,1,0,0]),woff.prefix(4) == Data("wOF2".utf8),
              let provider = CGDataProvider(data: ttf as CFData),let parsed = CGFont(provider),parsed.numberOfGlyphs == snapshot.draft.glyphs.count+1,
              parsed.postScriptName as String? == revision.family.replacingOccurrences(of: " ",with: "") else { throw WorkflowFailure.invalid("The compiled font did not match its expected glyphs and family.") }
        let model = try CreativeAssetFiles.decode(manifest,as: FontCompileManifest.self)
        let expectedRequest = try FontCompilerRequest.build(family: revision.family,glyphs: snapshot.draft.glyphs)
        guard model.schemaVersion == 1,model.family == revision.family,model.ttfSHA256 == revision.ttfSHA256,
              model.woff2SHA256 == revision.woff2SHA256,CutoutSourceInfo.validHash(model.requestSHA256),
              model.inputRequestSHA256 == TranscriptSourceMap.sha(expectedRequest),model.inputRequestSHA256 == compiled.requestSHA256,
              model.glyphs.count == snapshot.draft.glyphs.count,Set(model.glyphs.map(\.scalar)).count == model.glyphs.count,
              snapshot.draft.glyphs.allSatisfy({ glyph in model.glyphs.contains(where: { $0.scalar == glyph.scalar && $0.origin == glyph.origin && $0.sourceSHA256 == glyph.sourceSHA256 && $0.outlineSHA256 == glyph.outlineSHA256 && $0.licenseSHA256 == glyph.licenseSHA256 && $0.rasterSHA256 == glyph.rasterSHA256 }) }) else { throw WorkflowFailure.invalid("The compiled font provenance does not match the selected glyph revisions.") }
        let glyphs = try CreativeAssetFiles.encoder().encode(snapshot.draft.glyphs)
        guard TranscriptSourceMap.sha(glyphs) == revision.glyphsSHA256 else { throw ProjectFailure.invalidProject }
        if let expected = revision.licenseSHA256 {
            guard let license = compiled.files["OFL.txt"],TranscriptSourceMap.sha(license) == expected else { throw ProjectFailure.invalidProject }
        }
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let folder = try fonts(lease).child(snapshot.draft.id.uuidString), current = try read(folder,project: project.id,id: snapshot.draft.id)
        let revisions = try folder.child("revisions",create: true)
        var files = compiled.files; files["glyphs.json"] = glyphs; files["revision.json"] = try CreativeAssetFiles.encoder().encode(revision)
        guard Set(files.keys).isSubset(of: ["font.ttf","font.woff2","manifest.json","glyphs.json","revision.json","OFL.txt"]) else { throw ProjectFailure.invalidProject }
        if current.draft.currentFontRevisionID != revision.id {
            guard current.savedSHA256 == snapshot.savedSHA256,revision.parentRevisionID == current.draft.currentFontRevisionID else { throw WorkflowFailure.invalid("The mapping changed while this font compiled. Its earlier saved font remains available.") }
        }
        let output = try CreativeAssetFiles.publish(files,to: revision.id,in: revisions)
        if current.draft.currentFontRevisionID != revision.id {
            var next = current.draft; next.currentFontRevisionID = revision.id; next.generation += 1
            try lease.validate(project); try folder.checkPath(); try folder.replacePointer(encodeDraft(next),name: "draft.json")
        }
        return .init(revision: revision,snapshot: try read(folder,project: project.id,id: snapshot.draft.id),ttfURL: output.url.appendingPathComponent("font.ttf"),woff2URL: output.url.appendingPathComponent("font.woff2"))
    }
}
