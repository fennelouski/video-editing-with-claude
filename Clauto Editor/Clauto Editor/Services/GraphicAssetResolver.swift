import Foundation

actor GraphicAssetResolver {
    private let byteLimit: Int
    private let pixelLimit: Int
    init(byteLimit: Int = 256*1024*1024,pixelLimit: Int = 64_000_000) { self.byteLimit = max(1,min(byteLimit,256*1024*1024));self.pixelLimit = max(1,min(pixelLimit,64_000_000)) }
    private struct FontLink: Decodable {
        let schemaVersion: Int
        let id: UUID
        let fontID: UUID
        let projectID: UUID
        let ttfSHA256: String
        let licenseSHA256: String?
    }
    private func capture(_ scene: GraphicScene,project: Project) throws -> (GraphicResolvedAssets,[UUID:(bytes: Data,width: Int,height: Int)]) {
        try scene.validate()
        let lease = try ProjectMutationLease.acquire(project)
        var result = GraphicResolvedAssets(),images: [UUID:(bytes: Data,width: Int,height: Int)] = [:],consumed = 0,pixels = 0
        func read(_ folder: SourceRenderDirectory,_ name: String,_ cap: Int) throws -> Data {
            let available = byteLimit-consumed
            guard available>0 else { throw WorkflowFailure.invalid("This scene exceeds its image/font input budget. Use fewer or smaller assets.") }
            let bytes = try folder.read(name,limit: min(cap,available));consumed += bytes.count;return bytes
        }
        do {
            let assets = try lease.root.child("assets")
            for layer in scene.imageLayers {
                try Task.checkCancellation()
                let revision = try assets.child("generated-cutouts").child(layer.cutoutID.uuidString).child("revisions").child(layer.revisionID.uuidString)
                let manifestBytes = try read(revision,"manifest.json",65536),manifest = try CreativeAssetFiles.decode(manifestBytes,as: CutoutAssetRevision.self)
                guard manifest.width>0,manifest.height>0,manifest.width<=32000,manifest.height<=32000,manifest.width*manifest.height<=32_000_000 else { throw CutoutFailure.invalidImage }
                pixels += manifest.width*manifest.height;guard pixels<=pixelLimit else { throw WorkflowFailure.invalid("This scene exceeds its decoded image pixel budget. Use fewer or smaller cutouts.") }
                let bytes = try read(revision,"cutout.png",256*1024*1024)
                guard manifest.schemaVersion==1,manifest.id==layer.revisionID,manifest.assetID==layer.cutoutID,manifest.projectID==project.id,
                      manifest.imageSHA256==layer.imageSHA256,TranscriptSourceMap.sha(bytes)==layer.imageSHA256,manifest.classification==CutoutAssetRevision.extractionClassification else { throw CutoutFailure.changedSource }
                result.files[layer.id.uuidString+".png"] = bytes;images[layer.id] = (bytes,manifest.width,manifest.height)
                result.files[layer.id.uuidString+"-cutout.json"] = manifestBytes
            }
            for layer in scene.textLayers {
                guard let font = layer.font else { continue };try Task.checkCancellation()
                let revision = try assets.child("generated-fonts").child(font.fontID.uuidString).child("revisions").child(font.revisionID.uuidString)
                let manifestBytes = try read(revision,"revision.json",65536),manifest = try CreativeAssetFiles.decode(manifestBytes,as: FontLink.self),bytes = try read(revision,"font.ttf",32*1024*1024)
                guard manifest.schemaVersion==1,manifest.id==font.revisionID,manifest.fontID==font.fontID,manifest.projectID==project.id,
                      manifest.ttfSHA256==font.ttfSHA256,TranscriptSourceMap.sha(bytes)==font.ttfSHA256 else { throw CutoutFailure.changedSource }
                result.fonts[layer.id] = bytes;result.files[layer.id.uuidString+".ttf"] = bytes
                result.files[layer.id.uuidString+"-font.json"] = manifestBytes
                if let hash = manifest.licenseSHA256 {
                    let license = try read(revision,"OFL.txt",65536);guard TranscriptSourceMap.sha(license)==hash else { throw CutoutFailure.changedSource };result.files[layer.id.uuidString+"-OFL.txt"] = license
                }
            }
            guard result.files.values.reduce(0,{ $0+$1.count })<=256*1024*1024 else { throw WorkflowFailure.invalid("This scene references over 256 MiB of image/font inputs. Use fewer or smaller assets.") }
            try lease.validate(project)
        }
        withExtendedLifetime(lease) {}
        return (result,images)
    }
    func resolve(_ scene: GraphicScene,project: Project) throws -> GraphicResolvedAssets {
        // capture's local lease is destroyed before CPU-heavy conversion.
        var (result,images) = try capture(scene,project: project)
        for (name,bytes) in try GraphicTypography.files() { result.files[name] = bytes }
        for (id,value) in images {
            let decoded = try CutoutImageIO.decode(value.bytes,encodedLimit: 256*1024*1024)
            guard decoded.raster.width==value.width,decoded.raster.height==value.height else { throw CutoutFailure.changedSource }
            result.images[id] = decoded.raster
        }
        return result
    }
}

struct GraphicCutoutChoice: Identifiable,Sendable {
    let id: UUID
    let name: String
    let assetID: UUID
    let imageSHA256: String
}
struct GraphicFontChoice: Identifiable,Sendable {
    let id: UUID
    let name: String
    let fontID: UUID
    let ttfSHA256: String
}
extension GraphicAssetResolver {
    func choices(_ project: Project) throws -> (cutouts: [GraphicCutoutChoice],fonts: [GraphicFontChoice]) {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let state = try lease.root.child(".clauto"),assets = try lease.root.child("assets")
        struct CutoutIndex: Decodable { let schemaVersion: Int;let projectID: UUID;let assets: [UUID] }
        struct FontIndex: Decodable { let schemaVersion: Int;let projectID: UUID;let fontIDs: [UUID] }
        var cutouts: [GraphicCutoutChoice] = [],fonts: [GraphicFontChoice] = []
        if try CreativeAssetFiles.exists("cutout-index.json",in: state) {
            let index = try CreativeAssetFiles.decode(state.read("cutout-index.json",limit: 65536),as: CutoutIndex.self)
            guard index.schemaVersion==1,index.projectID==project.id,index.assets.count<=512,Set(index.assets).count==index.assets.count else { throw ProjectFailure.invalidProject }
            for id in index.assets {
                let folder = try assets.child("generated-cutouts").child(id.uuidString)
                let source = try CreativeAssetFiles.decode(folder.read("source.json",limit: 8192),as: CutoutSourceInfo.self)
                let draft = try CreativeAssetFiles.decode(folder.read("draft.json",limit: 4*1024*1024),as: CutoutDraft.self)
                try source.validate(project: project.id);try draft.validate(source: source);guard source.id==id else { throw CutoutFailure.changedSource }
                guard let revisionID = draft.currentRevisionID else { continue }
                let bytes = try folder.child("revisions").child(revisionID.uuidString).read("manifest.json",limit: 65536)
                let revision = try CreativeAssetFiles.decode(bytes,as: CutoutAssetRevision.self)
                guard revision.projectID==project.id,revision.assetID==id,revision.id==revisionID,CutoutSourceInfo.validHash(revision.imageSHA256) else { throw CutoutFailure.changedSource }
                cutouts.append(.init(id: revisionID,name: source.name,assetID: id,imageSHA256: revision.imageSHA256))
            }
        }
        if try CreativeAssetFiles.exists("font-index.json",in: state) {
            let index = try CreativeAssetFiles.decode(state.read("font-index.json",limit: 65536),as: FontIndex.self)
            guard index.schemaVersion==1,index.projectID==project.id,index.fontIDs.count<=512,Set(index.fontIDs).count==index.fontIDs.count else { throw ProjectFailure.invalidProject }
            for id in index.fontIDs {
                let folder = try assets.child("generated-fonts").child(id.uuidString)
                let draft = try CreativeAssetFiles.decode(folder.read("draft.json",limit: 16*1024*1024),as: FontStudioDraft.self)
                try draft.validate();guard draft.id==id,draft.projectID==project.id else { throw CutoutFailure.changedSource }
                guard let revisionID = draft.currentFontRevisionID else { continue }
                let bytes = try folder.child("revisions").child(revisionID.uuidString).read("revision.json",limit: 65536)
                let revision = try CreativeAssetFiles.decode(bytes,as: FontExportRevision.self)
                guard revision.projectID==project.id,revision.fontID==id,revision.id==revisionID,CutoutSourceInfo.validHash(revision.ttfSHA256) else { throw CutoutFailure.changedSource }
                fonts.append(.init(id: revisionID,name: draft.label,fontID: id,ttfSHA256: revision.ttfSHA256))
            }
        }
        try lease.validate(project);return (cutouts,fonts)
    }
}
