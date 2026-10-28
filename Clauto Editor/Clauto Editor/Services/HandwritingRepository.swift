import Foundation

/// Project-local immutable inputs. UUID publication and the project lease follow
/// the cutout/graphics stores; an interrupted save can retry its exact identity.
actor HandwritingRepository {
    private struct Entry: Codable { let assetID: UUID; let revisionID: UUID }
    private struct Catalog: Codable { var schemaVersion = 1; let projectID: UUID; var entries: [Entry] = [] }
    private struct StyleCatalog: Codable { var schemaVersion = 1; let projectID: UUID; var ids: [UUID] = [] }
    private struct PublicationClaim: Decodable { let schemaVersion: Int;let destination: String;let files: [String:String] }
    private func verifyClaim(_ folder: SourceRenderDirectory,id: UUID,files: [String:Data]) throws {
        let claim = try CreativeAssetFiles.decode(folder.read("creative-claim.json",limit: 16384),as: PublicationClaim.self)
        guard claim.schemaVersion == 1,claim.destination == id.uuidString,
              files.allSatisfy({ claim.files[$0.key] == TranscriptSourceMap.sha($0.value) }) else { throw CutoutFailure.changedSource }
    }
    private func parent(_ lease: ProjectMutationLease) throws -> SourceRenderDirectory {
        try lease.root.child("assets",create: true).child("handwriting",create: true)
    }
    private func catalog(_ lease: ProjectMutationLease,projectID: UUID) throws -> Catalog {
        let state = try lease.root.child(".clauto")
        guard try CreativeAssetFiles.exists("handwriting-index.json",in: state) else { return .init(projectID: projectID) }
        let value = try CreativeAssetFiles.decode(state.read("handwriting-index.json",limit: 512*1024),as: Catalog.self)
        guard value.schemaVersion == 1,value.projectID == projectID,value.entries.count<=2048,
              Set(value.entries.map(\.revisionID)).count == value.entries.count else { throw ProjectFailure.invalidProject }
        return value
    }
    private func read(_ folder: SourceRenderDirectory,projectID: UUID,assetID: UUID,revisionID: UUID) throws -> (HandwritingDocument,Data) {
        let documentBytes = try folder.read("document.json",limit: 2*1024*1024)
        let document = try CreativeAssetFiles.decode(documentBytes,as: HandwritingDocument.self)
        let original = try folder.read("original.image",limit: CutoutImageIO.sourceLimit)
        try verifyClaim(folder,id: revisionID,files: ["document.json":documentBytes,"original.image":original])
        guard document.projectID == projectID,document.id == assetID,document.revisionID == revisionID,
              document.provenance.sourceSHA256 == TranscriptSourceMap.sha(original) else { throw CutoutFailure.changedSource }
        let source = try CutoutImageIO.decode(original).raster
        try document.validate(width: source.width,height: source.height)
        return (document,original)
    }
    func list(_ project: Project) throws -> [HandwritingDocument] {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let root = try parent(lease)
        return try catalog(lease,projectID: project.id).entries.map { entry in
            try read(root.child(entry.assetID.uuidString).child(entry.revisionID.uuidString),projectID: project.id,assetID: entry.assetID,revisionID: entry.revisionID).0
        }
    }
    func load(_ project: Project,assetID: UUID,revisionID: UUID) throws -> (HandwritingDocument,Data) {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        guard try catalog(lease,projectID: project.id).entries.contains(where: { $0.assetID == assetID && $0.revisionID == revisionID }) else { throw ProjectFailure.invalidProject }
        return try read(parent(lease).child(assetID.uuidString).child(revisionID.uuidString),projectID: project.id,assetID: assetID,revisionID: revisionID)
    }
    func save(_ project: Project,document: HandwritingDocument,original: Data) throws -> URL {
        try Task.checkCancellation()
        let source = try CutoutImageIO.decode(original).raster
        guard document.projectID == project.id,document.provenance.sourceSHA256 == TranscriptSourceMap.sha(original) else { throw CutoutFailure.changedSource }
        try document.validate(width: source.width,height: source.height)
        let ink = try HandwritingRenderer().extract(source: source,recipe: document.recipe)
        let quality = try HandwritingRenderer().quality(ink: ink,recipe: document.recipe)
        if document.review.status == .approved {
            guard !document.recipe.strokes.isEmpty,quality.unrevealedPixels == 0,quality.boundaryInkPixels == 0 else {
                throw HandwritingFailure.invalid("Correct clipped or unrevealed ink before approval. Add paths or widen the reveal mask, then check the edges again.")
            }
        }
        let files = ["document.json":try CreativeAssetFiles.encoder().encode(document),
                     "original.image":original,"ink.png":try CutoutImageIO.png(ink),
                     "quality.json":try CreativeAssetFiles.encoder().encode(quality)]
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        var index = try catalog(lease,projectID: project.id)
        guard index.entries.contains(where: { $0.revisionID == document.revisionID }) || index.entries.count<2048 else { throw HandwritingFailure.invalid("This project has 2048 saved handwriting revisions. Use a new project for more artwork.") }
        if let parent = document.parentRevisionID {
            guard index.entries.contains(where: { $0.assetID == document.id && $0.revisionID == parent }) else { throw HandwritingFailure.invalid("Save or reopen the parent handwriting revision before creating this revision.") }
        } else if index.entries.contains(where: { $0.assetID == document.id && $0.revisionID != document.revisionID }) {
            throw HandwritingFailure.invalid("This asset already has history. Select its parent revision or create a new asset.")
        }
        guard !index.entries.contains(where: { $0.revisionID == document.revisionID && $0.assetID != document.id }) else { throw ProjectFailure.invalidProject }
        let asset = try parent(lease).child(document.id.uuidString,create: true)
        let folder = try CreativeAssetFiles.publish(files,to: document.revisionID,in: asset)
        try lease.validate(project)
        if !index.entries.contains(where: { $0.revisionID == document.revisionID }) {
            index.entries.append(.init(assetID: document.id,revisionID: document.revisionID))
            try lease.root.child(".clauto").replacePointer(CreativeAssetFiles.encoder().encode(index),name: "handwriting-index.json")
        }
        return folder.url
    }
    private func styleCatalog(_ lease: ProjectMutationLease,projectID: UUID) throws -> StyleCatalog {
        let state = try lease.root.child(".clauto")
        guard try CreativeAssetFiles.exists("handwriting-styles-index.json",in: state) else { return .init(projectID: projectID) }
        let index = try CreativeAssetFiles.decode(state.read("handwriting-styles-index.json",limit: 65536),as: StyleCatalog.self)
        guard index.schemaVersion == 1,index.projectID == projectID,index.ids.count<=128,Set(index.ids).count == index.ids.count else { throw ProjectFailure.invalidProject }
        return index
    }
    private func validateStyle(_ preset: HandwritingStylePreset,lease: ProjectMutationLease,projectID: UUID) throws {
        try preset.validate()
        let stored = try read(parent(lease).child(preset.sourceAssetID.uuidString).child(preset.sourceRevisionID.uuidString),projectID: projectID,assetID: preset.sourceAssetID,revisionID: preset.sourceRevisionID)
        let source = stored.0,raster = try CutoutImageIO.decode(stored.1).raster
        guard source.review == preset.review,source.recipe == preset.recipe,source.provenance == preset.provenance,
              source.exactText.utf8.elementsEqual(preset.exactText.utf8),source.locale == preset.locale,
              raster.width == preset.sourceWidth,raster.height == preset.sourceHeight else { throw HandwritingFailure.invalid("The style must match its saved, explicitly approved source revision exactly.") }
    }
    func saveStyle(_ project: Project,preset: HandwritingStylePreset) throws -> URL {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        try validateStyle(preset,lease: lease,projectID: project.id)
        var index = try styleCatalog(lease,projectID: project.id)
        guard index.ids.contains(preset.id) || index.ids.count<128 else { throw HandwritingFailure.invalid("This project has 128 approved styles. Choose an existing style or use another project.") }
        let folder = try CreativeAssetFiles.publish(["style.json":try CreativeAssetFiles.encoder().encode(preset)],to: preset.id,in: parent(lease).child("styles",create: true))
        if !index.ids.contains(preset.id) {
            index.ids.append(preset.id)
            try lease.root.child(".clauto").replacePointer(CreativeAssetFiles.encoder().encode(index),name: "handwriting-styles-index.json")
        }
        return folder.url
    }
    func approvedStyles(_ project: Project) throws -> [HandwritingStylePreset] {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let index = try styleCatalog(lease,projectID: project.id)
        if index.ids.isEmpty { return [] }
        let root = try parent(lease).child("styles")
        return try index.ids.map { id in
            let folder = try root.child(id.uuidString),bytes = try folder.read("style.json",limit: 2*1024*1024)
            try verifyClaim(folder,id: id,files: ["style.json":bytes])
            let preset = try CreativeAssetFiles.decode(bytes,as: HandwritingStylePreset.self)
            guard preset.id == id else { throw ProjectFailure.invalidProject }
            try validateStyle(preset,lease: lease,projectID: project.id);return preset
        }
    }
    func prepareExport(_ project: Project,document: HandwritingDocument,id: UUID) throws -> SourceRenderDirectory {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let revision = try parent(lease).child(document.id.uuidString).child(document.revisionID.uuidString)
        let saved = try read(revision,projectID: project.id,assetID: document.id,revisionID: document.revisionID).0
        guard saved == document,saved.review.status == .approved else { throw HandwritingFailure.invalid("Save and explicitly approve this exact revision before exporting.") }
        let exports = try revision.child("exports",create: true)
        guard !(try CreativeAssetFiles.exists(id.uuidString,in: exports)) else { throw HandwritingFailure.invalid("This export identity already exists. Its evidence is preserved; use a new export attempt identifier to retry.") }
        let folder = try exports.child(id.uuidString,create: true,exclusive: true)
        try folder.writeNew(CreativeAssetFiles.encoder().encode(document),name: "document.json")
        return folder
    }
}
