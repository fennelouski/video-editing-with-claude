import Foundation
import simd

struct GraphicVector: Codable,Equatable,Sendable {
    var x: Double
    var y: Double
    var z: Double = 0
    var finite: Bool { [x,y,z].allSatisfy { $0.isFinite && abs($0) <= 10000 } }
}
struct GraphicColor: Codable,Equatable,Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a = 1.0
    var valid: Bool { [r,g,b,a].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var float: SIMD4<Float> { .init(Float(r),Float(g),Float(b),Float(a)) }
    static let sage = Self(r: 0.32,g: 0.46,b: 0.37)
    static let oat = Self(r: 0.88,g: 0.82,b: 0.63)
}
struct ParticleGraphicModel: Codable,Equatable,Sendable {
    var count = 12
    var seed: UInt64 = 1
    var gravity = 0.0
    var restitution = 1.0
    var radius = 0.22
    var speed = 0.8
    var width = 10.0
    var height = 5.6
    func validate() throws {
        guard (1...64).contains(count),seed != 0,[gravity,restitution,radius,speed,width,height].allSatisfy(\.isFinite),
              (-20...20).contains(gravity),(0...1).contains(restitution),(0.02...0.5).contains(radius),
              (0...5).contains(speed),(2...30).contains(width),(2...30).contains(height),radius*2 < min(width,height),
              Double(count)*Double.pi*radius*radius < width*height*0.35 else { throw WorkflowFailure.invalid("Choose valid, uncrowded 2D particle parameters.") }
    }
}
enum GraphicElements {
    static let symbols = Set("H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og".split(separator: " ").map(String.init))
    /// Simple flat formulas only; parentheses, charges and isotope notation need
    /// explicit separate atom counts rather than an inferred chemistry model.
    static func parseFormula(_ text: String) throws -> [String:Int] {
        let input = Array(text.utf8);guard !input.isEmpty,input.count<=128 else { throw WorkflowFailure.invalid("Enter a simple formula such as H2O or CO2.") }
        var i = 0,result: [String:Int] = [:]
        while i<input.count {
            guard (65...90).contains(input[i]) else { throw WorkflowFailure.invalid("Use element symbols and counts, for example H2O. Parentheses and charges need separate explicit terms.") }
            var symbol = String(UnicodeScalar(input[i]));i += 1
            if i<input.count,(97...122).contains(input[i]) { symbol += String(UnicodeScalar(input[i]));i += 1 }
            let start = i;while i<input.count,(48...57).contains(input[i]) { i += 1 }
            let count = start==i ? 1:(Int(String(bytes: input[start..<i],encoding: .utf8) ?? "") ?? 0)
            guard symbols.contains(symbol),(1...100).contains(count),result[symbol,default: 0]+count<=100 else { throw WorkflowFailure.invalid("Use known element symbols with counts from 1 to 100.") }
            result[symbol,default: 0] += count
        }
        return result
    }
}
struct MolecularGraphicAtom: Codable,Equatable,Identifiable,Sendable {
    var id: Int
    var element: String
    var position: GraphicVector
    var radius: Double
    var color: GraphicColor
}
struct MolecularGraphicBond: Codable,Equatable,Identifiable,Sendable { var id = UUID();var first: Int;var second: Int;var order = 1 }
struct MolecularGraphicModel: Codable,Equatable,Sendable {
    var atoms: [MolecularGraphicAtom]
    var bonds: [MolecularGraphicBond]
    var spinRadiansPerSecond = 0.2
    var formula: [String:Int] { atoms.reduce(into: [:]) { $0[$1.element,default: 0] += 1 } }
    func validate() throws {
        guard !atoms.isEmpty,atoms.count <= 64,bonds.count <= 96,Set(atoms.map(\.id)).count == atoms.count,
              spinRadiansPerSecond.isFinite,abs(spinRadiansPerSecond)<=5,
              atoms.allSatisfy({ (1...1_000_000).contains($0.id) && GraphicElements.symbols.contains($0.element) && $0.position.finite && $0.radius.isFinite && (0.05...1).contains($0.radius) && $0.color.valid }) else { throw WorkflowFailure.invalid("This diagram needs unique atoms, valid coordinates and colors.") }
        guard Set(bonds.map(\.id)).count==bonds.count else { throw ProjectFailure.invalidProject }
        let ids = Set(atoms.map(\.id));var pairs = Set<String>()
        for bond in bonds {
            guard ids.contains(bond.first),ids.contains(bond.second),bond.first != bond.second,(1...3).contains(bond.order),
                  pairs.insert("\(min(bond.first,bond.second)):\(max(bond.first,bond.second))").inserted else { throw WorkflowFailure.invalid("A bond needs two distinct atoms and an explicit order.") }
        }
    }
}
struct AtomicGraphicModel: Codable,Equatable,Sendable {
    var protonCount = 6
    var electronCount = 6
    var orbitRadius = 2.0
    var radiansPerSecond = 0.8
    func validate() throws {
        guard (1...118).contains(protonCount),(0...32).contains(electronCount),orbitRadius.isFinite,(0.3...4).contains(orbitRadius),
              radiansPerSecond.isFinite,abs(radiansPerSecond)<=10 else { throw WorkflowFailure.invalid("Choose a bounded illustrative atom diagram.") }
    }
}
struct LinearMarketGraphicModel: Codable,Equatable,Sendable {
    var demandIntercept = 10.0
    var demandSlope = 1.0
    var supplyIntercept = 1.0
    var supplySlope = 0.5
    var demandShiftPerSecond = 0.0
    var maximumQuantity = 10.0
    var maximumPrice = 12.0
    func validate() throws {
        guard [demandIntercept,demandSlope,supplyIntercept,supplySlope,demandShiftPerSecond,maximumQuantity,maximumPrice].allSatisfy(\.isFinite),
              demandIntercept>=0,supplyIntercept>=0,(0.001...100).contains(demandSlope),(0.001...100).contains(supplySlope),
              abs(demandShiftPerSecond)<=10,(0.1...1000).contains(maximumQuantity),(0.1...1000).contains(maximumPrice) else { throw WorkflowFailure.invalid("Choose finite linear supply and demand parameters.") }
    }
    func equilibrium(at time: Double) throws -> (quantity: Double,price: Double) {
        try validate();guard time.isFinite,time>=0,time<=120 else { throw ProjectFailure.invalidProject }
        let quantity = (demandIntercept+demandShiftPerSecond*time-supplyIntercept)/(demandSlope+supplySlope)
        let price = supplyIntercept+supplySlope*quantity
        guard quantity>=0,price>=0,quantity<=maximumQuantity,price<=maximumPrice else { throw WorkflowFailure.invalid("The equilibrium is outside the plotted nonnegative range. Adjust the model or axes.") }
        return (quantity,price)
    }
}
struct ReactionGraphicTerm: Codable,Equatable,Identifiable,Sendable { var id = UUID();var coefficient: Int;var atoms: [String:Int] }
struct ReactionGraphicModel: Codable,Equatable,Sendable {
    var reactants: [ReactionGraphicTerm]
    var products: [ReactionGraphicTerm]
    var durationSeconds = 4.0
    func validate(requireBalanced: Bool = true) throws {
        guard !reactants.isEmpty,!products.isEmpty,reactants.count<=16,products.count<=16,durationSeconds.isFinite,(0.1...120).contains(durationSeconds) else { throw WorkflowFailure.invalid("Specify bounded reaction terms and duration.") }
        func totals(_ terms: [ReactionGraphicTerm]) throws -> [String:Int] {
            var result: [String:Int] = [:]
            for term in terms {
                guard (1...100).contains(term.coefficient),!term.atoms.isEmpty,term.atoms.count<=32,
                      term.atoms.allSatisfy({ GraphicElements.symbols.contains($0.key) && (1...100).contains($0.value) }) else { throw WorkflowFailure.invalid("Every reaction term needs explicit atom counts and a positive coefficient.") }
                for (element,count) in term.atoms { result[element,default: 0] += term.coefficient*count }
            }
            return result
        }
        guard Set((reactants+products).map(\.id)).count==reactants.count+products.count else { throw ProjectFailure.invalidProject }
        let input = try totals(reactants),output = try totals(products)
        guard input.values.reduce(0,+)<=96 else { throw WorkflowFailure.invalid("Use at most 96 displayed atoms in a reaction scene.") }
        guard !requireBalanced || input == output else { throw WorkflowFailure.invalid("The typed reaction is not atom-balanced. Correct its coefficients before export.") }
    }
}
struct GraphicMesh: Codable,Equatable,Sendable {
    var vertices: [GraphicVector]
    var triangles: [[Int]]
    var spinRadiansPerSecond = 0.3
    var color = GraphicColor.sage
    func validate() throws {
        guard (3...512).contains(vertices.count),!triangles.isEmpty,triangles.count<=128,vertices.allSatisfy(\.finite),
              triangles.allSatisfy({ $0.count==3 && Set($0).count==3 && $0.allSatisfy({ vertices.indices.contains($0) }) }),
              color.valid,spinRadiansPerSecond.isFinite,abs(spinRadiansPerSecond)<=5 else { throw WorkflowFailure.invalid("Choose a bounded triangle mesh with valid vertex indices.") }
        for face in triangles {
            let a = vertices[face[0]],b = vertices[face[1]],c = vertices[face[2]]
            let u = SIMD3(b.x-a.x,b.y-a.y,b.z-a.z),v = SIMD3(c.x-a.x,c.y-a.y,c.z-a.z)
            guard simd_length(simd_cross(u,v))>1e-10 else { throw WorkflowFailure.invalid("This mesh contains a degenerate triangle. Remove collapsed faces and retry.") }
        }
    }
    var center: GraphicVector {
        .init(x: ((vertices.map(\.x).min() ?? 0)+(vertices.map(\.x).max() ?? 0))/2,
              y: ((vertices.map(\.y).min() ?? 0)+(vertices.map(\.y).max() ?? 0))/2,
              z: ((vertices.map(\.z).min() ?? 0)+(vertices.map(\.z).max() ?? 0))/2)
    }
    static var cube: Self {
        .init(vertices: [.init(x: -1,y: -1,z: -1),.init(x: 1,y: -1,z: -1),.init(x: 1,y: 1,z: -1),.init(x: -1,y: 1,z: -1),.init(x: -1,y: -1,z: 1),.init(x: 1,y: -1,z: 1),.init(x: 1,y: 1,z: 1),.init(x: -1,y: 1,z: 1)],triangles: [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[3,7,6],[3,6,2],[0,4,7],[0,7,3],[1,2,6],[1,6,5]])
    }
}
struct GraphicAssumption: Codable,Equatable,Identifiable,Sendable { var id = UUID();var text: String }

struct GraphicScene: Codable,Equatable,Identifiable,Sendable {
    enum Kind: String,Codable,CaseIterable,Sendable { case particles,molecule,atom,reaction,object,market }
    var schemaVersion = 1
    var id = UUID()
    var kind: Kind
    var width = 1280
    var height = 720
    var frameCount = 96
    var particles: ParticleGraphicModel?
    var molecule: MolecularGraphicModel?
    var atom: AtomicGraphicModel?
    var reaction: ReactionGraphicModel?
    var object: GraphicMesh?
    var market: LinearMarketGraphicModel?
    var imageLayers: [GraphicImageLayer] = []
    var textLayers: [GraphicTextLayer] = []
    var assumptions: [GraphicAssumption] = []
    var reviewNotes = ""
    static let frameDuration = 1001.0/24000.0
    var validationLabel: String {
        switch kind {
        case .particles:"2D fixed-step toy physics · ideal disks, no air resistance"
        case .molecule:"Typed molecular diagram · geometry and chemistry need human review"
        case .atom:"Illustrative orbit diagram · not a quantum simulation"
        case .reaction:"Atom-balanced typed reaction · no kinetics or safety inference"
        case .object:"Projected triangle mesh · illustrative lighting"
        case .market:"Illustrative linear market · supplied assumptions, not a forecast"
        }
    }
    func validate(forRendering: Bool = true) throws {
        guard schemaVersion==1,width>=320,height>=240,width<=7680,height<=7680,width*height<=8_388_608,
              (1...2880).contains(frameCount),assumptions.count<=32,Set(assumptions.map(\.id)).count==assumptions.count,assumptions.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count<=2048 }),reviewNotes.utf8.count<=8192,
              [particles != nil,molecule != nil,atom != nil,reaction != nil,object != nil,market != nil].filter({ $0 }).count==1 else { throw WorkflowFailure.invalid("Choose one scene model, a supported canvas and up to 120 seconds of animation.") }
        guard imageLayers.count+textLayers.count<=16,Set(imageLayers.map(\.id)+textLayers.map(\.id)).count==imageLayers.count+textLayers.count else { throw ProjectFailure.invalidProject }
        for layer in imageLayers { try layer.transform.validate(frameCount: frameCount);guard CutoutSourceInfo.validHash(layer.imageSHA256) else { throw CutoutFailure.changedSource } }
        for layer in textLayers {
            try layer.transform.validate(frameCount: frameCount)
            guard !layer.text.isEmpty,layer.text.utf8.count<=4096,layer.fontSize.isFinite,(0.005...0.5).contains(layer.fontSize),layer.color.valid,layer.font.map({ CutoutSourceInfo.validHash($0.ttfSHA256) }) ?? true else { throw ProjectFailure.invalidProject }
        }
        switch kind {
        case .particles:guard let particles else { throw ProjectFailure.invalidProject };try particles.validate()
        case .molecule:guard let molecule else { throw ProjectFailure.invalidProject };try molecule.validate()
        case .atom:guard let atom else { throw ProjectFailure.invalidProject };try atom.validate()
        case .reaction:guard let reaction else { throw ProjectFailure.invalidProject };try reaction.validate(requireBalanced: forRendering)
        case .object:guard let object else { throw ProjectFailure.invalidProject };try object.validate()
        case .market:guard let market else { throw ProjectFailure.invalidProject };try market.validate();if forRendering { _ = try market.equilibrium(at: 0);_ = try market.equilibrium(at: Double(frameCount-1)*Self.frameDuration) }
        }
    }
}

/// An editor instance tags its own submissions. Observations carry a monotonic
/// controller revision so a delayed acknowledgement cannot erase newer typing.
struct GraphicFormulaSubmission: Equatable,Sendable {
    let id: UUID
    let editorID: UUID
    let atoms: [String:Int]
}
struct GraphicFormulaObservation: Equatable,Sendable {
    let atoms: [String:Int]
    let revision: Int
    let origin: GraphicFormulaSubmission?
    let historyEpoch: Int
}
struct GraphicFormulaEditorState: Equatable,Sendable {
    var text: String
    private let editorID = UUID()
    private var observedAtoms: [String:Int]
    private var observedRevision: Int
    private var observedHistoryEpoch: Int
    init(atoms: [String:Int],revision: Int = 0,historyEpoch: Int = 0) { text = Self.display(atoms);observedAtoms = atoms;observedRevision = revision;observedHistoryEpoch = historyEpoch }
    static func display(_ atoms: [String:Int]) -> String { atoms.keys.sorted().map { $0+(atoms[$0]==1 ? "":"\(atoms[$0]!)") }.joined() }
    func submission(_ atoms: [String:Int]) -> GraphicFormulaSubmission { .init(id: UUID(),editorID: editorID,atoms: atoms) }
    mutating func reconcile(_ observation: GraphicFormulaObservation) {
        guard observation.revision>=observedRevision else { return }
        let ownAcknowledgement = observation.origin.map { $0.editorID==editorID && $0.atoms==observation.atoms } ?? false
        if !ownAcknowledgement && (observation.historyEpoch>observedHistoryEpoch || observation.atoms != observedAtoms) { text = Self.display(observation.atoms) }
        observedAtoms = observation.atoms;observedRevision = observation.revision;observedHistoryEpoch = observation.historyEpoch
    }
    /// Explicit external restoration used by non-UI consumers.
    mutating func reconcile(_ atoms: [String:Int]) {
        reconcile(.init(atoms: atoms,revision: observedRevision+1,origin: nil,historyEpoch: observedHistoryEpoch+1))
    }
}
