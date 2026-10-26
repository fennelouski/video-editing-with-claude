import Foundation

enum StudioStarter: String,CaseIterable,Identifiable,Sendable {
    case title,lowerThird,chapter,molecule,particles,object
    var id: String { rawValue }
    var title: String { switch self { case .title:"Film title";case .lowerThird:"Lower third";case .chapter:"Chapter card";case .molecule:"Molecule explainer";case .particles:"Particle motion";case .object:"3D object" } }
    var detail: String { switch self { case .title:"A clean title and subtitle";case .lowerThird:"Name and context over footage";case .chapter:"A clear section break";case .molecule:"Editable atoms, bonds and rotation";case .particles:"Ready-to-edit toy physics";case .object:"A lit, rotating mesh" } }
    var kind: GraphicScene.Kind { switch self { case .title,.lowerThird,.chapter:.titleCard;case .molecule:.molecule;case .particles:.particles;case .object:.object } }
    func scene(projectName: String,aspect: String) -> GraphicScene {
        var scene = GraphicScene.preset(kind)
        if aspect == "9:16" { scene.width = 720;scene.height = 1280 }
        switch self {
        case .title:
            scene.textLayers = [.init(text: projectName,fontSize: 0.09,transform: .init(x: 0.5,y: 0.40,width: 0.86,height: 0.35)),.init(text: "A film about the details",fontSize: 0.04,transform: .init(x: 0.5,y: 0.64,width: 0.82,height: 0.12))]
        case .lowerThird:
            scene.textLayers = [.init(text: "Name or key idea",fontSize: 0.065,transform: .init(x: 0.34,y: 0.76,width: 0.58,height: 0.13)),.init(text: "Add a short explanation",fontSize: 0.035,transform: .init(x: 0.34,y: 0.88,width: 0.58,height: 0.09))]
        case .chapter:
            scene.textLayers = [.init(text: "01",fontSize: 0.13,transform: .init(x: 0.5,y: 0.28,width: 0.8,height: 0.22)),.init(text: "The next chapter",fontSize: 0.075,transform: .init(x: 0.5,y: 0.58,width: 0.86,height: 0.24))]
        default:break
        }
        return scene
    }
}
