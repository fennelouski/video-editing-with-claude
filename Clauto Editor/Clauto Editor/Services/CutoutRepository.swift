import Foundation

/// Project-local source, mask bases and output revisions are immutable. Only the
/// draft/index pointers change, under the same lease used by every project writer.
actor CutoutRepository: CutoutAssetStoring {
    private struct Index: Codable { var schemaVersion = 1; let projectID: UUID; var assets: [UUID] }
    private struct DirectorySet { let lease: ProjectMutationLease; let state: SourceRenderDirectory; let assets: SourceRenderDirectory }
    private func directories(_ project: Project) throws -> DirectorySet {
        let lease = try ProjectMutationLease.acquire(project)
        let state = try lease.root.child(".clauto",create: true)
        let assets = try lease.root.child("assets",create: true).child("generated-cutouts",create: true)
        try lease.validate(project); return .init(lease: lease,state: state,assets: assets)
    }
    private func index(_ state: SourceRenderDirectory,project: UUID) throws -> Index {
        guard try CreativeAssetFiles.exists("cutout-index.json",in: state) else { return .init(projectID: project,assets: []) }
        let value = try CreativeAssetFiles.decode(state.read("cutout-index.json",limit: 65_536),as: Index.self)
        guard value.schemaVersion == 1, value.projectID == project, value.assets.count <= 512,
              Set(value.assets).count == value.assets.count else { throw ProjectFailure.invalidProject }; return value
    }
    func readImageFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw CutoutFailure.invalidImage }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let folder = try SourceRenderDirectory.open(canonical.deletingLastPathComponent())
        let bytes = try folder.read(canonical.lastPathComponent,limit: CutoutImageIO.sourceLimit)
        try folder.checkPath(); return bytes
    }
    func list(_ project: Project) throws -> [CutoutSourceInfo] {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        return try index(set.state,project: project.id).assets.map { id in
            let asset = try set.assets.child(id.uuidString)
            let info = try CreativeAssetFiles.decode(asset.read("source.json",limit: 8192),as: CutoutSourceInfo.self)
            try info.validate(project: project.id); guard info.id == id else { throw CutoutFailure.changedSource }; return info
        }
    }
    /// The caller retains this ID/timestamp and the original bytes on failure, so
    /// an uncertain publication can be retried without creating a second asset.
    func create(_ project: Project,id: UUID,createdMilliseconds: Int64,name: String,bytes: Data) throws -> CutoutDraftSnapshot {
        let decoded = try CutoutImageIO.decode(bytes), raster = decoded.raster
        let info = CutoutSourceInfo(id: id,projectID: project.id,createdMilliseconds: createdMilliseconds,name: name,
                                    encodedSHA256: decoded.originalSHA256,rasterSHA256: TranscriptSourceMap.sha(raster.rgba),
                                    orientation: decoded.orientation,width: raster.width,height: raster.height,colorFormat: "Oriented straight sRGB RGBA8")
        try info.validate(project: project.id)
        let draft = CutoutDraft(assetID: id,projectID: project.id,sourceSHA256: info.encodedSHA256,generation: 0,recipe: .init())
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        var catalog = try index(set.state,project: project.id)
        guard catalog.assets.contains(id) || catalog.assets.count < 512 else { throw WorkflowFailure.invalid("This project has 512 cutout sources. Create another project to continue.") }
        let asset = try CreativeAssetFiles.publish(["original.image":bytes,"source.json":try CreativeAssetFiles.encoder().encode(info)],to: id,in: set.assets)
        if !(try CreativeAssetFiles.exists("draft.json",in: asset)) { try asset.replacePointer(CreativeAssetFiles.encoder().encode(draft),name: "draft.json") }
        if !catalog.assets.contains(id) {
            catalog.assets.append(id); try set.lease.validate(project)
            try set.state.replacePointer(CreativeAssetFiles.encoder().encode(catalog),name: "cutout-index.json")
        }
        return try read(asset,project: project.id,id: id)
    }
    func load(_ project: Project,id: UUID) throws -> CutoutDraftSnapshot {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        guard try index(set.state,project: project.id).assets.contains(id) else { throw CutoutFailure.changedSource }
        return try read(set.assets.child(id.uuidString),project: project.id,id: id)
    }
    private func read(_ asset: SourceRenderDirectory,project: UUID,id: UUID) throws -> CutoutDraftSnapshot {
        let info = try CreativeAssetFiles.decode(asset.read("source.json",limit: 8192),as: CutoutSourceInfo.self)
        try info.validate(project: project); guard info.id == id else { throw CutoutFailure.changedSource }
        let bytes = try asset.read("draft.json",limit: 4*1024*1024)
        let draft = try CreativeAssetFiles.decode(bytes,as: CutoutDraft.self); try draft.validate(source: info)
        return .init(source: info,draft: draft,savedSHA256: TranscriptSourceMap.sha(bytes))
    }
    func source(_ project: Project,id: UUID) throws -> CutoutDecodedSource {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        let asset = try set.assets.child(id.uuidString), snapshot = try read(asset,project: project.id,id: id)
        return try decodedSource(asset,info: snapshot.source)
    }
    private func decodedSource(_ asset: SourceRenderDirectory,info: CutoutSourceInfo) throws -> CutoutDecodedSource {
        try verifiedOriginal(asset,info: info).decoded
    }
    private func verifiedOriginal(_ asset: SourceRenderDirectory,info: CutoutSourceInfo) throws -> (bytes: Data,decoded: CutoutDecodedSource) {
        let bytes = try asset.read("original.image",limit: CutoutImageIO.sourceLimit)
        let decoded = try CutoutImageIO.decode(bytes)
        guard decoded.originalSHA256 == info.encodedSHA256, decoded.orientation == info.orientation,
              decoded.raster.width == info.width, decoded.raster.height == info.height,
              TranscriptSourceMap.sha(decoded.raster.rgba) == info.rasterSHA256 else { throw CutoutFailure.changedSource }; return (bytes,decoded)
    }
    /// Store detector output without activating it. Late detector results cannot
    /// replace a newer draft; activation uses the draft's exact saved-base hash.
    func storeDetection(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,detection: CutoutDetection) throws -> CutoutMaskBasis {
        try detection.validate()
        guard detection.width == snapshot.source.width, detection.height == snapshot.source.height else { throw CutoutFailure.invalidMask }
        var files: [String:Data] = [:], hashes: [String:String] = [:]
        for subject in detection.subjects { let name = String(subject.id); hashes[name] = TranscriptSourceMap.sha(subject.mask); files["subject-\(name).gray"] = subject.mask }
        let basis = CutoutMaskBasis(id: id,sourceRasterSHA256: snapshot.source.rasterSHA256,width: detection.width,height: detection.height,
                                   model: detection.model,modelRevision: detection.modelRevision,subjectSHA256: hashes,manualSHA256: nil,manualSourceSHA256: nil)
        files["basis.json"] = try CreativeAssetFiles.encoder().encode(basis)
        try publishBasis(project,snapshot: snapshot,id: id,files: files); return basis
    }
    func storeManualMask(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,encodedMask: Data) throws -> CutoutMaskBasis {
        let decoded = try CutoutImageIO.decode(encodedMask)
        let mask = try CutoutImageIO.manualMask(decoded,width: snapshot.source.width,height: snapshot.source.height)
        let basis = CutoutMaskBasis(id: id,sourceRasterSHA256: snapshot.source.rasterSHA256,width: snapshot.source.width,height: snapshot.source.height,
                                   model: "Supplied mask image",modelRevision: 1,subjectSHA256: [:],manualSHA256: TranscriptSourceMap.sha(mask),manualSourceSHA256: decoded.originalSHA256)
        try publishBasis(project,snapshot: snapshot,id: id,files: ["basis.json":try CreativeAssetFiles.encoder().encode(basis),"manual.gray":mask,"manual-original.image":encodedMask]); return basis
    }
    private func publishBasis(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,files: [String:Data]) throws {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        let asset = try set.assets.child(snapshot.source.id.uuidString), current = try read(asset,project: project.id,id: snapshot.source.id)
        guard current.source == snapshot.source else { throw CutoutFailure.changedSource }
        _ = try CreativeAssetFiles.publish(files,to: id,in: asset.child("mask-bases",create: true)); try set.lease.validate(project)
    }
    private func basis(_ asset: SourceRenderDirectory,snapshot: CutoutDraftSnapshot) throws -> CutoutBasisPixels? {
        guard let id = snapshot.draft.basisID else { return nil }
        let folder = try asset.child("mask-bases").child(id.uuidString)
        let m = try CreativeAssetFiles.decode(folder.read("basis.json",limit: 32_768),as: CutoutMaskBasis.self)
        guard m.schemaVersion == 1, m.id == id, m.sourceRasterSHA256 == snapshot.source.rasterSHA256,
              m.width == snapshot.source.width, m.height == snapshot.source.height, !m.model.isEmpty, m.model.utf8.count <= 1024,
              m.modelRevision >= 0, m.subjectSHA256.count <= 32,
              m.subjectSHA256.count*m.width*m.height <= 64*1024*1024 else { throw CutoutFailure.invalidMask }
        if let hash = m.manualSHA256 {
            guard m.subjectSHA256.isEmpty, CutoutSourceInfo.validHash(hash), let originalHash = m.manualSourceSHA256,
                  CutoutSourceInfo.validHash(originalHash), snapshot.draft.recipe.manualMaskSHA256 == hash else { throw CutoutFailure.invalidMask }
            let bytes = try folder.read("manual.gray",limit: m.width*m.height)
            guard bytes.count == m.width*m.height, TranscriptSourceMap.sha(bytes) == hash,
                  TranscriptSourceMap.sha(try folder.read("manual-original.image",limit: CutoutImageIO.sourceLimit)) == originalHash else { throw CutoutFailure.invalidMask }
            return .init(manifest: m,detection: nil,manual: bytes)
        }
        guard m.manualSourceSHA256 == nil, snapshot.draft.recipe.manualMaskSHA256 == nil else { throw CutoutFailure.invalidMask }
        let subjects: [CutoutSubject] = try m.subjectSHA256.map { key,hash in
            guard let id = Int(key), id > 0, String(id) == key, key.utf8.count <= 10, CutoutSourceInfo.validHash(hash) else { throw CutoutFailure.invalidMask }
            let bytes = try folder.read("subject-\(key).gray",limit: m.width*m.height)
            guard TranscriptSourceMap.sha(bytes) == hash else { throw CutoutFailure.invalidMask }; return .init(id: id,mask: bytes)
        }.sorted { $0.id < $1.id }
        let detection = CutoutDetection(width: m.width,height: m.height,subjects: subjects,model: m.model,modelRevision: m.modelRevision)
        try detection.validate(); return .init(manifest: m,detection: detection,manual: nil)
    }
    func save(_ project: Project,base: CutoutDraftSnapshot,draft: CutoutDraft) throws -> CutoutDraftSnapshot {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        let asset = try set.assets.child(base.source.id.uuidString), current = try read(asset,project: project.id,id: base.source.id)
        guard current.source == base.source, draft.generation == base.draft.generation,
              draft.currentRevisionID == base.draft.currentRevisionID else { throw CutoutFailure.storageConflict }
        try draft.validate(source: current.source)
        var next = draft; next.generation += 1; try next.validate(source: current.source)
        if current.draft == next { return current }
        guard current.savedSHA256 == base.savedSHA256 else { throw CutoutFailure.storageConflict }
        let snapshot = CutoutDraftSnapshot(source: current.source,draft: next,savedSHA256: "")
        _ = try basis(asset,snapshot: snapshot)
        try set.lease.validate(project); try asset.checkPath()
        try asset.replacePointer(CreativeAssetFiles.encoder().encode(next),name: "draft.json")
        return try read(asset,project: project.id,id: base.source.id)
    }
    func masks(_ project: Project,snapshot: CutoutDraftSnapshot) throws -> CutoutBasisPixels? {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        let asset = try set.assets.child(snapshot.source.id.uuidString)
        guard try read(asset,project: project.id,id: snapshot.source.id).source == snapshot.source else { throw CutoutFailure.changedSource }
        return try basis(asset,snapshot: snapshot)
    }
    /// Preserve this window's corrections as a separate source/revision family.
    /// The other writer's asset and every existing revision remain untouched.
    func copyDraft(_ project: Project,snapshot: CutoutDraftSnapshot,draft: CutoutDraft,newID: UUID,createdMilliseconds: Int64) throws -> CutoutDraftSnapshot {
        try draft.validate(source: snapshot.source)
        let set = try directories(project)
        let asset = try set.assets.child(snapshot.source.id.uuidString)
        guard try read(asset,project: project.id,id: snapshot.source.id).source == snapshot.source else { throw CutoutFailure.changedSource }
        let original = try verifiedOriginal(asset,info: snapshot.source).bytes
        let local = CutoutDraftSnapshot(source: snapshot.source,draft: draft,savedSHA256: snapshot.savedSHA256)
        let masks = try basis(asset,snapshot: local)
        // Publish the copy under this same lease; never acquire it recursively.
        return try copyAfterReading(project,old: snapshot,recipe: draft.recipe,original: original,masks: masks,newID: newID,createdMilliseconds: createdMilliseconds,lease: set.lease)
    }
    private func copyAfterReading(_ project: Project,old: CutoutDraftSnapshot,recipe: CutoutRecipe,original: Data,masks: CutoutBasisPixels?,newID: UUID,createdMilliseconds: Int64,lease: ProjectMutationLease) throws -> CutoutDraftSnapshot {
        // Work stays under a single lease: copy immutable bytes, then publish
        // the new draft and catalog pointer without recursively acquiring it.
        try lease.validate(project)
        let assets = try lease.root.child("assets").child("generated-cutouts"), state = try lease.root.child(".clauto")
        var info = old.source
        info = .init(id: newID,projectID: project.id,createdMilliseconds: createdMilliseconds,name: info.name,
                     encodedSHA256: info.encodedSHA256,rasterSHA256: info.rasterSHA256,orientation: info.orientation,width: info.width,height: info.height,colorFormat: info.colorFormat)
        var catalog = try index(state,project: project.id)
        guard catalog.assets.contains(newID) || catalog.assets.count < 512 else { throw CutoutFailure.storageConflict }
        let folder = try CreativeAssetFiles.publish(["original.image":original,"source.json":try CreativeAssetFiles.encoder().encode(info)],to: newID,in: assets)
        let copy = CutoutDraft(assetID: newID,projectID: project.id,sourceSHA256: info.encodedSHA256,generation: 0,basisID: masks?.manifest.id,recipe: recipe)
        if let masks {
            var files: [String:Data] = ["basis.json":try CreativeAssetFiles.encoder().encode(masks.manifest)]
            if let detection = masks.detection { for subject in detection.subjects { files["subject-\(subject.id).gray"] = subject.mask } }
            if let manual = masks.manual {
                files["manual.gray"] = manual
                let oldFolder = try assets.child(old.source.id.uuidString).child("mask-bases").child(masks.manifest.id.uuidString)
                files["manual-original.image"] = try oldFolder.read("manual-original.image",limit: CutoutImageIO.sourceLimit)
            }
            _ = try CreativeAssetFiles.publish(files,to: masks.manifest.id,in: folder.child("mask-bases",create: true))
        }
        try copy.validate(source: info)
        let bytes = try CreativeAssetFiles.encoder().encode(copy)
        if try CreativeAssetFiles.exists("draft.json",in: folder) {
            guard try folder.read("draft.json",limit: 4*1024*1024) == bytes else { throw CutoutFailure.storageConflict }
        } else { try folder.replacePointer(bytes,name: "draft.json") }
        if !catalog.assets.contains(newID) { catalog.assets.append(newID); try state.replacePointer(CreativeAssetFiles.encoder().encode(catalog),name: "cutout-index.json") }
        try lease.validate(project); return try read(folder,project: project.id,id: newID)
    }
    func preview(_ project: Project,snapshot: CutoutDraftSnapshot) throws -> CutoutPixels {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        let asset = try set.assets.child(snapshot.source.id.uuidString), current = try read(asset,project: project.id,id: snapshot.source.id)
        guard current.source == snapshot.source else { throw CutoutFailure.changedSource }
        try snapshot.draft.validate(source: current.source)
        let source = try decodedSource(asset,info: current.source), masks = try basis(asset,snapshot: snapshot)
        return try CutoutMaskProcessor().render(source.raster,recipe: snapshot.draft.recipe,detection: masks?.detection,manualMask: masks?.manual)
    }
    /// Retain the attempt ID and created time until acknowledged. Repeated exact
    /// requests return the same immutable revision; changed words require a new ID.
    func export(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,created: Date) throws -> CutoutExport {
        let set = try directories(project); defer { withExtendedLifetime(set.lease) {} }
        let asset = try set.assets.child(snapshot.source.id.uuidString), current = try read(asset,project: project.id,id: snapshot.source.id)
        let revisions = try asset.child("revisions",create: true)
        if current.draft.currentRevisionID == id {
            let folder = try revisions.child(id.uuidString)
            let revision = try CreativeAssetFiles.decode(folder.read("manifest.json",limit: 32_768),as: CutoutAssetRevision.self)
            let requestedHash = TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(snapshot.draft.recipe))
            let requestedBasis = try basis(asset,snapshot: snapshot)
            let basisHash = try requestedBasis.map { TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode($0.manifest)) }
            guard revision.schemaVersion == 1, revision.id == id, revision.assetID == snapshot.source.id, revision.projectID == project.id,
                  revision.sourceSHA256 == snapshot.source.encodedSHA256, revision.sourceRasterSHA256 == snapshot.source.rasterSHA256,
                  revision.width == snapshot.source.width, revision.height == snapshot.source.height,
                  revision.maskBasisID == snapshot.draft.basisID, revision.maskBasisSHA256 == basisHash,
                  revision.recipeSHA256 == requestedHash, revision.classification == CutoutAssetRevision.extractionClassification,
                  TranscriptSourceMap.sha(try folder.read("recipe.json",limit: 4*1024*1024)) == revision.recipeSHA256,
                  TranscriptSourceMap.sha(try folder.read("mask.png",limit: 256*1024*1024)) == revision.maskSHA256,
                  TranscriptSourceMap.sha(try folder.read("cutout.png",limit: 256*1024*1024)) == revision.imageSHA256 else { throw CutoutFailure.storageConflict }
            return .init(revision: revision,snapshot: current,pngURL: folder.url.appendingPathComponent("cutout.png"))
        }
        guard current.savedSHA256 == snapshot.savedSHA256, current.source == snapshot.source else { throw CutoutFailure.storageConflict }
        let decoded = try decodedSource(asset,info: current.source), masks = try basis(asset,snapshot: current)
        let pixels = try CutoutMaskProcessor().render(decoded.raster,recipe: current.draft.recipe,detection: masks?.detection,manualMask: masks?.manual)
        let png = try CutoutImageIO.png(pixels.image), mask = try CutoutImageIO.maskPNG(pixels.mask,width: pixels.image.width,height: pixels.image.height)
        let recipe = try CreativeAssetFiles.encoder().encode(current.draft.recipe)
        let revision = CutoutAssetRevision(schemaVersion: 1,id: id,assetID: current.source.id,projectID: project.id,parentRevisionID: current.draft.currentRevisionID,created: created,
                                          sourceName: current.source.name,sourceSHA256: current.source.encodedSHA256,sourceRasterSHA256: current.source.rasterSHA256,
                                          sourceOrientation: current.source.orientation,width: current.source.width,height: current.source.height,
                                          recipeSHA256: TranscriptSourceMap.sha(recipe),imageSHA256: TranscriptSourceMap.sha(png),maskSHA256: TranscriptSourceMap.sha(mask),
                                          model: masks?.manifest.model ?? "Manual brush",modelRevision: masks?.manifest.modelRevision ?? 1,
                                          maskBasisID: current.draft.basisID,maskBasisSHA256: try masks.map { TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode($0.manifest)) },
                                          foregroundPixels: pixels.foregroundPixels,classification: CutoutAssetRevision.extractionClassification)
        let folder = try CreativeAssetFiles.publish(["cutout.png":png,"mask.png":mask,"recipe.json":recipe,"manifest.json":try CreativeAssetFiles.encoder().encode(revision)],to: id,in: revisions)
        var next = current.draft; next.currentRevisionID = id; next.generation += 1; try next.validate(source: current.source)
        try set.lease.validate(project); try asset.checkPath(); try folder.checkPath()
        try asset.replacePointer(CreativeAssetFiles.encoder().encode(next),name: "draft.json")
        return .init(revision: revision,snapshot: try read(asset,project: project.id,id: current.source.id),pngURL: folder.url.appendingPathComponent("cutout.png"))
    }
}
