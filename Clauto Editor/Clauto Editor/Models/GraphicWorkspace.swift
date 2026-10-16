import Foundation

struct GraphicObjectSource: Codable,Equatable,Sendable {
    var id: UUID
    var name: String
    var sha256: String
}
struct GraphicSceneDraft: Codable,Equatable,Identifiable,Sendable {
    var schemaVersion = 1
    let id: UUID
    let projectID: UUID
    var generation = 0
    var label: String
    var scene: GraphicScene
    var objectSource: GraphicObjectSource?
    var currentRevisionID: UUID?
    func validate() throws {
        guard schemaVersion==1,scene.id==id,(0...1_000_000).contains(generation),!label.isEmpty,label.utf8.count<=128,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProjectFailure.invalidProject }
        try scene.validate(forRendering: false)
        if let source = objectSource {
            guard scene.kind == .object,!source.name.isEmpty,source.name.utf8.count<=512,CutoutSourceInfo.validHash(source.sha256) else { throw ProjectFailure.invalidProject }
        }
    }
}
struct GraphicDraftSnapshot: Equatable,Sendable {
    let draft: GraphicSceneDraft
    let savedSHA256: String
}
struct GraphicWorkspaceSummary: Identifiable,Sendable {
    let id: UUID
    let label: String
    let kind: GraphicScene.Kind
}
extension GraphicScene {
    static func preset(_ kind: Kind) -> Self {
        switch kind {
        case .particles:return .init(kind: kind,particles: .init())
        case .atom:return .init(kind: kind,atom: .init())
        case .market:return .init(kind: kind,market: .init())
        case .object:return .init(kind: kind,object: .cube)
        case .molecule:return .init(kind: kind,molecule: .init(atoms: [.init(id: 1,element: "O",position: .init(x: 0,y: 0),radius: 0.4,color: .sage),.init(id: 2,element: "H",position: .init(x: -0.7907,y: 0.6122),radius: 0.24,color: .oat),.init(id: 3,element: "H",position: .init(x: 0.7907,y: 0.6122),radius: 0.24,color: .oat)],bonds: [.init(first: 1,second: 2),.init(first: 1,second: 3)]))
        case .reaction:return .init(kind: kind,reaction: .init(reactants: [.init(coefficient: 2,atoms: ["H":2]),.init(coefficient: 1,atoms: ["O":2])],products: [.init(coefficient: 2,atoms: ["H":2,"O":1])]))
        }
    }
}
