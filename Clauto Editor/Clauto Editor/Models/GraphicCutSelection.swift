import Foundation
import Darwin

/// Frozen project-local movie identity and placement in a separate saved-cut export.
struct GraphicCutSelection: Codable,Equatable,Sendable {
    let projectID: UUID
    let sceneID: UUID
    let revisionID: UUID
    let manifestSHA256: String
    let movieSHA256: String
    var at = 0.0
    var sourceStart = 0.0
    var duration: Double
    var scale = 1.0
    var x = 0.0
    var y = 0.0
    var relativeManifestPath: String { "assets/generated-scenes/\(sceneID)/revisions/\(revisionID)/revision.json" }
    func validate(cutDuration: Double) throws {
        guard CutoutSourceInfo.validHash(manifestSHA256),CutoutSourceInfo.validHash(movieSHA256),
              [at,sourceStart,duration,scale,x,y,cutDuration].allSatisfy(\.isFinite),
              at>=0,sourceStart>=0,duration>0,at+duration<=cutDuration+1e-8,
              (0.1...4).contains(scale),abs(x)<=100,abs(y)<=100,
              DerivativeRequest.snapped(duration)>0,
              DerivativeRequest.snapped(at)+DerivativeRequest.snapped(duration)<=cutDuration+1e-8 else {
            throw WorkflowFailure.invalid("Choose graphic timing inside this export and supported framing. The graphic must span at least one frame.")
        }
    }
    func validateSource(_ revision: GraphicExportRevision,project: UUID) throws {
        guard projectID==project,revision.schemaVersion==1,revision.projectID==project,revision.sceneID==sceneID,revision.id==revisionID,
              (1...2880).contains(revision.proof.frameCount),revision.proof.decodedEveryFrame,revision.proof.codec=="ap4h",
              revision.proof.durationValue==Int64(revision.proof.frameCount)*1001,revision.proof.durationScale==24000,revision.proof.maximumEndpointAlphaError<=2,
              revision.files["animation.mov"]?.sha256==movieSHA256,revision.proof.movie==revision.files["animation.mov"],
              sourceStart+duration<=Double(revision.proof.frameCount)*GraphicScene.frameDuration+1e-8,
              DerivativeRequest.snapped(sourceStart)+DerivativeRequest.snapped(duration)<=Double(revision.proof.frameCount)*GraphicScene.frameDuration+1e-8 else {
            throw WorkflowFailure.invalid("The selected graphic revision or range changed. Choose an exported revision without holding or padding its missing frames.")
        }
    }
}
struct GraphicCutChoice: Identifiable,Sendable {
    var id: UUID { selection.revisionID }
    let label: String
    let validationLabel: String
    let selection: GraphicCutSelection
}

private struct GraphicCutPlacement: Decodable,Equatable {
    let at: Double
    let sourceStart: Double
    let duration: Double
    let scale: Double
    let x: Double
    let y: Double
    enum CodingKeys: String,CodingKey { case at,duration,scale,x,y;case sourceStart = "source_start" }
}
private struct GraphicCompositionMetadata: Decodable {
    let request: GraphicCutSelection
    let placement: GraphicCutPlacement
    let sourceDimensions: [Int]
    let sourceFrameCount: Int
    let revisionPath: String
    let rendererVersion: String
    let metalShaderSHA256: String
    let validationLabel: String
    let assumptions: [String]
    let sourceSHA256: [String:String]
    enum CodingKeys: String,CodingKey {
        case request,placement,assumptions
        case sourceDimensions = "source_dimensions",sourceFrameCount = "source_frame_count",revisionPath = "revision_path"
        case rendererVersion = "renderer_version",metalShaderSHA256 = "metal_shader_sha256",validationLabel = "validation_label",sourceSHA256 = "source_sha256"
    }
}
extension GraphicCutSelection {
    func verifyMetadata(_ object: [String:Any],revisionBytes: Data,sceneBytes: Data,project: Project) throws {
        let metadata = try JSONDecoder().decode(GraphicCompositionMetadata.self,from: JSONSerialization.data(withJSONObject: object))
        let revision = try CreativeAssetFiles.decode(revisionBytes,as: GraphicExportRevision.self)
        let scene = try CreativeAssetFiles.decode(sceneBytes,as: GraphicSceneDraft.self)
        try scene.validate();try scene.scene.validate();try validateSource(revision,project: project.id)
        let placement = GraphicCutPlacement(at: DerivativeRequest.snapped(at),sourceStart: DerivativeRequest.snapped(sourceStart),duration: DerivativeRequest.snapped(duration),scale: scale,x: x,y: y)
        let manifest = try GraphicCompositionPaths.canonical(project.folder.appendingPathComponent(relativeManifestPath))
        let folder = (manifest as NSString).deletingLastPathComponent
        var sources = [manifest:manifestSHA256]
        guard revision.files.count<=100 else { throw ProjectFailure.invalidProject }
        for (name,record) in revision.files {
            guard name != ".",name != "..",name.range(of: "^[A-Za-z0-9_.-]{1,100}$",options: .regularExpression) != nil,
                  CutoutSourceInfo.validHash(record.sha256),record.byteCount>0,record.byteCount<=GraphicArtifactFiles.movieLimit else { throw ProjectFailure.invalidProject }
            sources[(folder as NSString).appendingPathComponent(name)] = record.sha256
        }
        let checks: [(String,Bool)] = [
            ("manifestBytes",TranscriptSourceMap.sha(revisionBytes)==manifestSHA256),
            ("request",metadata.request==self),("placement",metadata.placement==placement),
            ("sceneIdentity",scene.projectID==project.id && scene.id==sceneID),
            ("sceneHash",revision.draftSHA256==TranscriptSourceMap.sha(sceneBytes) && revision.files["scene.json"]?.sha256==revision.draftSHA256),
            ("sceneDimensions",scene.scene.width==revision.proof.width && scene.scene.height==revision.proof.height && scene.scene.frameCount==revision.proof.frameCount),
            ("metadataDimensions",metadata.sourceDimensions==[revision.proof.width,revision.proof.height] && metadata.sourceFrameCount==revision.proof.frameCount),
            ("sourcePathsAndHashes",metadata.revisionPath==manifest && metadata.sourceSHA256==sources),
            ("renderer",metadata.rendererVersion==revision.rendererVersion && metadata.metalShaderSHA256==revision.metalShaderSHA256),
            ("classification",metadata.validationLabel==revision.validationLabel && revision.validationLabel==scene.scene.validationLabel),
            ("assumptions",metadata.assumptions==revision.assumptions && revision.assumptions==scene.scene.assumptions.map(\.text))]
        let failures = checks.filter { !$0.1 }.map(\.0)
        guard failures.isEmpty else { throw GraphicCompositionMismatch(fields: failures) }
    }
}

struct GraphicCompositionMismatch: LocalizedError,Sendable {
    let fields: [String]
    var errorDescription: String? { "The composed graphic receipt does not match the selected immutable scene, movie and placement. The parent cut remains unchanged." }
}

/// Python resolves physical POSIX paths. Foundation may preserve the /var alias;
/// compare one physical spelling across the native/engine boundary.
enum GraphicCompositionPaths {
    static func canonical(_ url: URL) throws -> String {
        guard url.isFileURL,let pointer = url.path.withCString({ Darwin.realpath($0,nil) }) else { throw ProjectFailure.invalidProject }
        defer { free(pointer) };return String(cString: pointer)
    }
}
