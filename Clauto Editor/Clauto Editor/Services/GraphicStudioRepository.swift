import Foundation

actor GraphicStudioRepository {
    private struct Index: Codable { var schemaVersion = 1;let projectID: UUID;var scenes: [UUID] }
    private nonisolated func parent(_ lease: ProjectMutationLease) throws -> SourceRenderDirectory { try lease.root.child("assets",create: true).child("generated-scenes",create: true) }
    private nonisolated func index(_ folder: SourceRenderDirectory,project: UUID) throws -> Index {
        guard try CreativeAssetFiles.exists("graphics-index.json",in: folder) else { return .init(projectID: project,scenes: []) }
        let value = try CreativeAssetFiles.decode(folder.read("graphics-index.json",limit: 65536),as: Index.self)
        guard value.schemaVersion==1,value.projectID==project,value.scenes.count<=512,Set(value.scenes).count==value.scenes.count else { throw ProjectFailure.invalidProject };return value
    }
    private nonisolated func encoded(_ draft: GraphicSceneDraft) throws -> Data {
        try draft.validate();let bytes = try CreativeAssetFiles.encoder().encode(draft)
        guard bytes.count<=1024*1024 else { throw WorkflowFailure.invalid("This scene exceeds 1 MiB of editable inputs. Its previous saved revision remains available.") };return bytes
    }
    private nonisolated func read(_ folder: SourceRenderDirectory,project: UUID,id: UUID) throws -> GraphicDraftSnapshot {
        let bytes = try folder.read("draft.json",limit: 1024*1024),draft = try CreativeAssetFiles.decode(bytes,as: GraphicSceneDraft.self)
        try draft.validate();guard draft.id==id,draft.projectID==project else { throw ProjectFailure.invalidProject };return .init(draft: draft,savedSHA256: TranscriptSourceMap.sha(bytes))
    }
    func list(_ project: Project) throws -> [GraphicWorkspaceSummary] {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let root = try parent(lease),state = try lease.root.child(".clauto")
        return try index(state,project: project.id).scenes.map { id in let draft = try read(root.child(id.uuidString),project: project.id,id: id).draft;return .init(id: id,label: draft.label,kind: draft.scene.kind) }
    }
    func create(_ project: Project,id: UUID,label: String,scene: GraphicScene) throws -> GraphicDraftSnapshot {
        var scene = scene;scene.id = id
        let value = GraphicSceneDraft(id: id,projectID: project.id,label: label,scene: scene),bytes = try encoded(value)
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let root = try parent(lease),state = try lease.root.child(".clauto");var catalog = try index(state,project: project.id)
        guard catalog.scenes.contains(id) || catalog.scenes.count<512 else { throw WorkflowFailure.invalid("This project has 512 scenes. Create another project to continue.") }
        let folder = try CreativeAssetFiles.publish(["origin.json":try CreativeAssetFiles.encoder().encode(["sceneID":id.uuidString,"projectID":project.id.uuidString])],to: id,in: root)
        if !(try CreativeAssetFiles.exists("draft.json",in: folder)) { try folder.replacePointer(bytes,name: "draft.json") }
        if !catalog.scenes.contains(id) { catalog.scenes.append(id);try state.replacePointer(CreativeAssetFiles.encoder().encode(catalog),name: "graphics-index.json") }
        return try read(folder,project: project.id,id: id)
    }
    func load(_ project: Project,id: UUID) throws -> GraphicDraftSnapshot {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        return try read(parent(lease).child(id.uuidString),project: project.id,id: id)
    }
    func save(_ project: Project,base: GraphicDraftSnapshot,draft: GraphicSceneDraft) throws -> GraphicDraftSnapshot {
        try draft.validate()
        guard draft.id==base.draft.id,draft.projectID==project.id,draft.generation==base.draft.generation,draft.currentRevisionID==base.draft.currentRevisionID else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let folder = try parent(lease).child(draft.id.uuidString),current = try read(folder,project: project.id,id: draft.id)
        var next = draft;next.generation += 1
        if current.draft==next { return current }
        guard current.savedSHA256==base.savedSHA256 else { throw WorkflowFailure.invalid("This scene changed in another window. Your current inputs remain available to keep as a separate scene.") }
        if let source = next.objectSource { _ = try objectBytes(folder,source: source,mesh: next.scene.object) }
        try lease.validate(project);try folder.replacePointer(encoded(next),name: "draft.json");return try read(folder,project: project.id,id: draft.id)
    }
    func importOBJ(_ project: Project,sceneID: UUID,id: UUID,name: String,bytes: Data) throws -> (GraphicObjectSource,GraphicMesh) {
        let mesh = try GraphicMeshImport.parseOBJ(bytes),source = GraphicObjectSource(id: id,name: name,sha256: TranscriptSourceMap.sha(bytes))
        guard !name.isEmpty,name.utf8.count<=512,!name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let folder = try parent(lease).child(sceneID.uuidString);_ = try read(folder,project: project.id,id: sceneID)
        _ = try CreativeAssetFiles.publish(["original.obj":bytes,"source.json":try CreativeAssetFiles.encoder().encode(source)],to: id,in: folder.child("sources",create: true))
        return (source,mesh)
    }
    func copyDraft(_ project: Project,snapshot: GraphicDraftSnapshot,draft: GraphicSceneDraft,newID: UUID) throws -> GraphicDraftSnapshot {
        try draft.validate();guard draft.id==snapshot.draft.id,draft.projectID==project.id else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let root = try parent(lease),old = try root.child(draft.id.uuidString),state = try lease.root.child(".clauto")
        let original: Data?
        if let source = draft.objectSource { original = try objectBytes(old,source: source,mesh: draft.scene.object) } else { original = nil }
        var catalog = try index(state,project: project.id);guard catalog.scenes.contains(newID) || catalog.scenes.count<512 else { throw ProjectFailure.invalidProject }
        let origin = ["sceneID":newID.uuidString,"projectID":project.id.uuidString,"copiedFrom":draft.id.uuidString,"capturedDraftSHA256":TranscriptSourceMap.sha(try encoded(draft))]
        let folder = try CreativeAssetFiles.publish(["origin.json":try CreativeAssetFiles.encoder().encode(origin)],to: newID,in: root)
        if let source = draft.objectSource,let original { _ = try CreativeAssetFiles.publish(["original.obj":original,"source.json":try CreativeAssetFiles.encoder().encode(source)],to: source.id,in: folder.child("sources",create: true)) }
        var scene = draft.scene;scene.id = newID
        let copy = GraphicSceneDraft(id: newID,projectID: project.id,label: draft.label,scene: scene,objectSource: draft.objectSource),bytes = try encoded(copy)
        if try CreativeAssetFiles.exists("draft.json",in: folder) { guard try folder.read("draft.json",limit: 1024*1024)==bytes else { throw WorkflowFailure.invalid("The recovered scene already has a newer correction. Your local inputs remain available for a separate copy.") } }
        else { try folder.replacePointer(bytes,name: "draft.json") }
        if !catalog.scenes.contains(newID) { catalog.scenes.append(newID);try state.replacePointer(CreativeAssetFiles.encoder().encode(catalog),name: "graphics-index.json") }
        try lease.validate(project);return try read(folder,project: project.id,id: newID)
    }
    private nonisolated func objectBytes(_ scene: SourceRenderDirectory,source: GraphicObjectSource,mesh: GraphicMesh?) throws -> Data {
        let folder = try scene.child("sources").child(source.id.uuidString)
        guard try CreativeAssetFiles.decode(folder.read("source.json",limit: 8192),as: GraphicObjectSource.self)==source else { throw CutoutFailure.changedSource }
        let bytes = try folder.read("original.obj",limit: 1024*1024),parsed = try GraphicMeshImport.parseOBJ(bytes)
        guard TranscriptSourceMap.sha(bytes)==source.sha256,parsed.vertices==mesh?.vertices,parsed.triangles==mesh?.triangles else { throw CutoutFailure.changedSource };return bytes
    }
}

extension GraphicStudioRepository {
    func prepareExport(_ project: Project,snapshot: GraphicDraftSnapshot,id: UUID,assets: GraphicResolvedAssets) async throws -> GraphicExportJob {
        try await GraphicArtifactFiles.executor.perform { job in try self.prepareExportLocal(project,snapshot: snapshot,id: id,assets: assets,check: job.checkCancellation) }
    }
    private nonisolated func prepareExportLocal(_ project: Project,snapshot: GraphicDraftSnapshot,id: UUID,assets: GraphicResolvedAssets,check: () throws -> Void) throws -> GraphicExportJob {
        try snapshot.draft.scene.validate();try check()
        guard assets.files.count<=80,assets.files.keys.allSatisfy(CreativeAssetFiles.validLeaf),assets.files.values.reduce(0,{ $0+$1.count })<=272*1024*1024 else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let scene = try parent(lease).child(snapshot.draft.id.uuidString)
        guard try read(scene,project: project.id,id: snapshot.draft.id)==snapshot else { throw WorkflowFailure.invalid("This scene changed before export. Your current inputs remain available; save them and retry.") }
        let folder = try scene.child("revisions",create: true).child(id.uuidString,create: true,exclusive: true)
        var files = assets.files;files["scene.json"] = try encoded(snapshot.draft)
        if let source = snapshot.draft.objectSource { files["original.obj"] = try objectBytes(scene,source: source,mesh: snapshot.draft.scene.object) }
        var records: [String:GraphicFileRecord] = [:]
        for name in files.keys.sorted() {
            try check();let bytes = files[name]!;guard !bytes.isEmpty,bytes.count<=256*1024*1024 else { throw ProjectFailure.invalidProject }
            try folder.writeNew(bytes,name: name);records[name] = .init(sha256: TranscriptSourceMap.sha(bytes),byteCount: Int64(bytes.count))
        }
        struct Origin: Codable { let schemaVersion: Int;let id: UUID;let sceneID: UUID;let projectID: UUID;let draftSHA256: String;let files: [String:GraphicFileRecord] }
        let origin = Origin(schemaVersion: 1,id: id,sceneID: snapshot.draft.id,projectID: project.id,draftSHA256: snapshot.savedSHA256,files: records)
        try folder.writeNew(CreativeAssetFiles.encoder().encode(origin),name: "export-origin.json");try folder.checkPath();try lease.validate(project)
        return .init(id: id,createdMilliseconds: Int64((Date().timeIntervalSince1970*1000).rounded()),snapshot: snapshot,folder: folder,capturedFiles: records)
    }
    func publishExport(_ project: Project,job: GraphicExportJob,output: GraphicAnimationOutput,proof: GraphicMovieProof) async throws -> GraphicExportResult {
        try await GraphicArtifactFiles.executor.perform { waiting in try self.publishExportLocal(project,job: job,output: output,proof: proof,check: waiting.checkCancellation) }
    }
    private nonisolated func publishExportLocal(_ project: Project,job: GraphicExportJob,output: GraphicAnimationOutput,proof: GraphicMovieProof,check: () throws -> Void) throws -> GraphicExportResult {
        try check();try job.snapshot.draft.scene.validate()
        guard output.movieURL==job.folder.url.appendingPathComponent("animation.mov"),proof.decodedEveryFrame,proof.maximumEndpointAlphaError<=2,
              proof.frameCount==job.snapshot.draft.scene.frameCount,proof.width==job.snapshot.draft.scene.width,proof.height==job.snapshot.draft.scene.height,
              proof.movie==output.movie,output.frames==proof.frameCount,output.durationValue==proof.durationValue,output.durationScale==proof.durationScale,output.codec==proof.codec,
              proof.codec=="ap4h",proof.durationValue==Int64(proof.frameCount)*1001,proof.durationScale==24000 else { throw ProjectFailure.invalidProject }
        // Check all frozen inputs before admitting the movie. No project lease is
        // retained during rendering or full AVFoundation decoding.
        for (name,record) in job.capturedFiles { guard try GraphicArtifactFiles.digest(job.folder,name: name,limit: record.byteCount,check: check)==record else { throw CutoutFailure.changedSource } }
        guard try GraphicArtifactFiles.digest(job.folder,name: "animation.mov",check: check)==proof.movie else { throw CutoutFailure.changedSource }
        let finalCut = try GraphicFinalCutXML.make(scene: job.snapshot.draft.scene,label: job.snapshot.draft.label,movie: output.movieURL)
        let additions = ["frame-first.png":output.firstPNG,"frame-last.png":output.finalPNG,"timeline.fcpxml":finalCut,"decode-proof.json":try CreativeAssetFiles.encoder().encode(proof)]
        var records = job.capturedFiles;records["animation.mov"] = proof.movie
        for (name,bytes) in additions {
            if try CreativeAssetFiles.exists(name,in: job.folder) { guard try job.folder.read(name,limit: bytes.count)==bytes else { throw CutoutFailure.storageConflict } }
            else { try job.folder.writeNew(bytes,name: name) }
            records[name] = .init(sha256: TranscriptSourceMap.sha(bytes),byteCount: Int64(bytes.count))
        }
        let revision = GraphicExportRevision(schemaVersion: 1,id: job.id,sceneID: job.snapshot.draft.id,projectID: project.id,parentRevisionID: job.snapshot.draft.currentRevisionID,createdMilliseconds: job.createdMilliseconds,draftSHA256: job.snapshot.savedSHA256,rendererVersion: GraphicMetalRenderer.implementationVersion,metalShaderSHA256: GraphicMetalRenderer.shaderSHA256,files: records,proof: proof,validationLabel: job.snapshot.draft.scene.validationLabel,assumptions: job.snapshot.draft.scene.assumptions.map(\.text))
        let revisionBytes = try CreativeAssetFiles.encoder().encode(revision)
        if try CreativeAssetFiles.exists("revision.json",in: job.folder) { guard try job.folder.read("revision.json",limit: 65536)==revisionBytes else { throw CutoutFailure.storageConflict } }
        else { try job.folder.writeNew(revisionBytes,name: "revision.json") }
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let scene = try parent(lease).child(job.snapshot.draft.id.uuidString),current = try read(scene,project: project.id,id: job.snapshot.draft.id)
        let actual = try scene.child("revisions").child(job.id.uuidString)
        guard actual.identity==job.folder.identity else { throw CutoutFailure.changedSource }
        var next = job.snapshot.draft;next.generation += 1;next.currentRevisionID = job.id
        if current.draft != next {
            if current != job.snapshot {
                return .init(becameCurrent: false,revision: revision,snapshot: current,movieURL: output.movieURL,timelineURL: actual.url.appendingPathComponent("timeline.fcpxml"))
            }
            try check();try lease.validate(project);try actual.checkPath();try scene.replacePointer(encoded(next),name: "draft.json")
        }
        let saved = try read(scene,project: project.id,id: job.snapshot.draft.id)
        return .init(revision: revision,snapshot: saved,movieURL: output.movieURL,timelineURL: actual.url.appendingPathComponent("timeline.fcpxml"))
    }
    func currentExport(_ project: Project,sceneID: UUID) async throws -> GraphicExportResult? {
        try await GraphicArtifactFiles.executor.perform { job in try self.currentExportLocal(project,sceneID: sceneID,check: job.checkCancellation) }
    }
    private nonisolated func currentExportLocal(_ project: Project,sceneID: UUID,check: () throws -> Void) throws -> GraphicExportResult? {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let scene = try parent(lease).child(sceneID.uuidString),snapshot = try read(scene,project: project.id,id: sceneID)
        guard let id = snapshot.draft.currentRevisionID else { return nil }
        let folder = try scene.child("revisions").child(id.uuidString),revision = try CreativeAssetFiles.decode(folder.read("revision.json",limit: 65536),as: GraphicExportRevision.self)
        guard revision.schemaVersion==1,revision.id==id,revision.sceneID==sceneID,revision.projectID==project.id,revision.files.count<=100,Set(["scene.json","animation.mov","annotation-font.ttf","annotation-OFL.txt","frame-first.png","frame-last.png","timeline.fcpxml","decode-proof.json"]).isSubset(of: Set(revision.files.keys)),
              revision.files["scene.json"]?.sha256==revision.draftSHA256,revision.files["animation.mov"]==revision.proof.movie,
              revision.proof.decodedEveryFrame,revision.proof.codec=="ap4h",revision.proof.maximumEndpointAlphaError<=2 else { throw CutoutFailure.changedSource }
        for (name,record) in revision.files {
            guard record.byteCount>0,record.byteCount<=GraphicArtifactFiles.movieLimit,CutoutSourceInfo.validHash(record.sha256),try GraphicArtifactFiles.digest(folder,name: name,limit: record.byteCount,check: check)==record else { throw CutoutFailure.changedSource }
        }
        let captured = try CreativeAssetFiles.decode(folder.read("scene.json",limit: 1024*1024),as: GraphicSceneDraft.self)
        try captured.validate();try captured.scene.validate()
        guard try folder.read("decode-proof.json",limit: 65536)==CreativeAssetFiles.encoder().encode(revision.proof) else { throw CutoutFailure.changedSource }
        for layer in captured.scene.imageLayers {
            guard revision.files[layer.id.uuidString+".png"]?.sha256==layer.imageSHA256,revision.files[layer.id.uuidString+"-cutout.json"] != nil else { throw CutoutFailure.changedSource }
        }
        for layer in captured.scene.textLayers where layer.font != nil {
            guard let font = layer.font,revision.files[layer.id.uuidString+".ttf"]?.sha256==font.ttfSHA256,revision.files[layer.id.uuidString+"-font.json"] != nil else { throw CutoutFailure.changedSource }
        }
        guard captured.id==sceneID,captured.projectID==project.id,captured.scene.validationLabel==revision.validationLabel,captured.scene.assumptions.map(\.text)==revision.assumptions,
              revision.proof.frameCount==captured.scene.frameCount,revision.proof.width==captured.scene.width,revision.proof.height==captured.scene.height,
              revision.proof.durationValue==Int64(captured.scene.frameCount)*1001,revision.proof.durationScale==24000,
              try folder.read("timeline.fcpxml",limit: 65536)==GraphicFinalCutXML.make(scene: captured.scene,label: captured.label,movie: folder.url.appendingPathComponent("animation.mov")) else { throw CutoutFailure.changedSource }
        try lease.validate(project);return .init(revision: revision,snapshot: snapshot,movieURL: folder.url.appendingPathComponent("animation.mov"),timelineURL: folder.url.appendingPathComponent("timeline.fcpxml"))
    }
}
