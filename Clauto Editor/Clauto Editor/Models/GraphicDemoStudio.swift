import Foundation

/// Reusable illustrative rigs. Textures remain scanned project assets; these
/// presets supply geometry, palette, light and frame timing, never fake grain.
struct GraphicDemoRig: Codable,Equatable,Sendable {
    enum Template: String,Codable,CaseIterable,Sendable {
        case hero,inspection,overhead
        var title: String { switch self { case .hero:"Hero object";case .inspection:"Inspect the form";case .overhead:"Overhead explanation" } }
    }
    enum Action: String,Codable,CaseIterable,Sendable {
        case hold,turntable,rock,reveal
        var title: String { switch self { case .hold:"Hold";case .turntable:"Turntable";case .rock:"Gentle rock";case .reveal:"Reveal" } }
    }
    enum Material: String,Codable,CaseIterable,Sendable {
        case sageClay,oatCard,walnutIron
        var title: String { switch self { case .sageClay:"Sage clay";case .oatCard:"Oat card";case .walnutIron:"Walnut iron" } }
        /// Exact Sage & Oat base tokens from scripts/config.py; lighting varies
        /// luminance while preserving warm matte surfaces and bounded highlights.
        var baseColor: GraphicColor {
            switch self {
            case .sageClay:.init(r: 138.0/255,g: 154.0/255,b: 123.0/255)
            case .oatCard:.init(r: 232.0/255,g: 223.0/255,b: 200.0/255)
            case .walnutIron:.init(r: 74.0/255,g: 60.0/255,b: 46.0/255)
            }
        }
    }
    enum Light: String,Codable,CaseIterable,Sendable {
        case warmSoft,raking
        var title: String { self == .warmSoft ? "Warm softbox":"Raking edge light" }
    }
    var template: Template = .hero
    var action: Action = .rock
    var yawRadians = 0.6
    var pitchRadians = 0.45
    var sweepRadians = 1.2
    var seed: UInt64 = 1
    var stepFrames = 2
    var material: Material = .sageClay
    var light: Light = .warmSoft
    static func preset(_ template: Template) -> Self {
        switch template {
        case .hero:.init()
        case .inspection:.init(template: template,action: .turntable,yawRadians: 0.6,pitchRadians: 0.65,sweepRadians: Double.pi*2)
        case .overhead:.init(template: template,action: .hold,yawRadians: 0,pitchRadians: 1.25,sweepRadians: 0)
        }
    }
    func validate() throws {
        guard [yawRadians,pitchRadians,sweepRadians].allSatisfy(\.isFinite),abs(yawRadians)<=Double.pi*2,
              abs(pitchRadians)<=Double.pi/2,(0...Double.pi*2).contains(sweepRadians),(1...9_007_199_254_740_991).contains(seed),stepFrames==2 else {
            throw WorkflowFailure.invalid("Use finite studio camera angles, a positive seed and two-frame motion steps.")
        }
    }
}

struct GraphicDemoProvenance: Codable,Equatable,Sendable {
    enum RightsStatus: String,Codable,Sendable { case localUnverified = "local-unverified",cc0,licensed }
    var assetID: String
    var name: String
    var creator: String
    var sourceURL: String
    var license: String
    var sourceSHA256: String
    var modifications: String
    var rightsStatus: RightsStatus
    var sourceFiles: [String:String]
    var licenseText: String
    func validate() throws {
        let required = [assetID,name,creator,license,modifications]
        guard required.allSatisfy({ !$0.isEmpty && $0.utf8.count<=4096 }),sourceURL.utf8.count<=4096,
              CutoutSourceInfo.validHash(sourceSHA256),licenseText.utf8.count<=16_384,sourceFiles.count<=16,
              sourceFiles.allSatisfy({ $0.key.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$",options: .regularExpression) != nil && CutoutSourceInfo.validHash($0.value) }) else {
            throw WorkflowFailure.invalid("Keep bounded model provenance, original SHA-256 values and the recorded license text with this demo.")
        }
        guard rightsStatus == .localUnverified || (!licenseText.isEmpty && !sourceURL.isEmpty && !sourceFiles.isEmpty) else {
            throw WorkflowFailure.invalid("A licensed library model needs its recorded license text, source URL and original file hashes. Use local-unverified only when rights remain unverified.")
        }
    }
}

/// Prepared requests contain geometry, not external paths. Import never follows
/// model URLs or guesses licenses; the local library preparer verifies source bytes.
struct GraphicDemoRequest: Codable,Equatable,Sendable {
    let schemaVersion: Int
    let requestID: UUID
    let label: String
    let width: Int
    let height: Int
    let frameCount: Int
    let rig: GraphicDemoRig
    let mesh: GraphicMesh
    let provenance: GraphicDemoProvenance
    let assumptions: [String]
    let reviewNotes: String

    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty,bytes.count<=1024*1024 else { throw WorkflowFailure.invalid("Choose a prepared demo JSON smaller than 1 MiB; reduce the model if needed.") }
        try TranscriptJSONKeys.validate(bytes)
        let raw = try JSONSerialization.jsonObject(with: bytes,options: [.fragmentsAllowed])
        func object(_ value: Any?,_ keys: Set<String>) throws -> [String:Any] {
            guard let value = value as? [String:Any],Set(value.keys)==keys else { throw WorkflowFailure.invalid("The prepared demo has missing or unknown fields. Regenerate it with scripts/demo_studio.py prepare.") };return value
        }
        let value = try object(raw,["schemaVersion","requestID","label","width","height","frameCount","rig","mesh","provenance","assumptions","reviewNotes"])
        _ = try object(value["rig"],["template","action","yawRadians","pitchRadians","sweepRadians","seed","stepFrames","material","light"])
        let mesh = try object(value["mesh"],["vertices","triangles","spinRadiansPerSecond","color"])
        _ = try object(mesh["color"],["r","g","b","a"])
        guard let vertices = mesh["vertices"] as? [Any],vertices.count<=20_000 else { throw ProjectFailure.invalidProject }
        for vertex in vertices { _ = try object(vertex,["x","y","z"]) }
        _ = try object(value["provenance"],["assetID","name","creator","sourceURL","license","sourceSHA256","modifications","rightsStatus","sourceFiles","licenseText"])
        let request = try CreativeAssetFiles.decoder().decode(Self.self,from: bytes)
        _ = try request.scene();return request
    }
    func scene() throws -> GraphicScene {
        guard schemaVersion==1,!label.isEmpty,label.utf8.count<=128,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (2...2880).contains(frameCount),frameCount%2==0,assumptions.count<=32 else {
            throw WorkflowFailure.invalid("Use a named version-1 demo, an even frame count from 2 to 2880 and at most 32 assumptions.")
        }
        try rig.validate();try provenance.validate();try mesh.validate()
        var scene = GraphicScene(kind: .object,width: width,height: height,frameCount: frameCount,object: mesh)
        scene.id = requestID;scene.demoRig = rig;scene.demoProvenance = provenance;scene.reviewNotes = reviewNotes
        scene.assumptions = assumptions.enumerated().map { index,text in
            let hex = Array(TranscriptSourceMap.sha(Data("\(requestID.uuidString):assumption:\(index)".utf8)).prefix(32))
            let token = String(hex[0..<8])+"-"+String(hex[8..<12])+"-"+String(hex[12..<16])+"-"+String(hex[16..<20])+"-"+String(hex[20..<32])
            return .init(id: UUID(uuidString: token)!,text: text)
        }
        try scene.validate()
        // The repository has the same cap. Refuse before creating a project scene
        // rather than publishing an input that cannot later save or export.
        let envelope = GraphicSceneDraft(id: scene.id,projectID: requestID,label: label,scene: scene)
        guard try CreativeAssetFiles.encoder().encode(envelope).count<=1024*1024 else { throw WorkflowFailure.invalid("This prepared scene exceeds the 1 MiB editable-input budget. Reduce its model and prepare it again.") }
        return scene
    }
}
