import Foundation
import simd

struct GraphicAnnotation: Sendable {
    var text: String
    var x: Double
    var y: Double
    var size: Double
    var color = GraphicColor(r: 0.12,g: 0.17,b: 0.14)
    var requireFullText = false
    var plate = true
}
struct GraphicBuiltFrame: Sendable {
    var primitives: [GraphicPrimitiveGPU]
    var annotations: [GraphicAnnotation]
}
struct GraphicFrameBuilder: Sendable {
    let scene: GraphicScene
    private var simulation: GraphicParticleSimulation?
    init(_ scene: GraphicScene) throws {
        try scene.validate();self.scene = scene
        if let particles = scene.particles { simulation = try .init(particles) }
    }
    mutating func frame(_ index: Int) throws -> GraphicBuiltFrame {
        try Task.checkCancellation();guard (0..<scene.frameCount).contains(index) else { throw ProjectFailure.invalidProject }
        let width = Double(scene.width),height = Double(scene.height),time = Double(index)*GraphicScene.frameDuration
        let box = (x: width*0.08,y: height*0.08,w: width*0.84,h: height*0.63),scale = min(box.w/10,box.h/6)
        var shapes: [GraphicPrimitiveGPU] = [],labels: [GraphicAnnotation] = []
        func line(_ ax: Double,_ ay: Double,_ bx: Double,_ by: Double,_ color: GraphicColor = .sage,_ weight: Double = 2) -> GraphicPrimitiveGPU {
            .segment(x0: Float(ax),y0: Float(ay),x1: Float(bx),y1: Float(by),width: Float(max(1,weight*width/1280)),color: color)
        }
        func circle(_ x: Double,_ y: Double,_ r: Double,_ color: GraphicColor) -> GraphicPrimitiveGPU { .circle(x: Float(x),y: Float(y),radius: Float(r),color: color) }
        func rotate(_ v: GraphicVector,_ angle: Double) -> SIMD3<Double> {
            let a = SIMD3(v.x*cos(angle)+v.z*sin(angle),v.y,-v.x*sin(angle)+v.z*cos(angle)),tilt = 0.25
            return .init(a.x,a.y*cos(tilt)-a.z*sin(tilt),a.y*sin(tilt)+a.z*cos(tilt))
        }
        func projected(_ v: SIMD3<Double>,_ zoom: Double = 1) -> SIMD2<Double> { .init(box.x+box.w/2+v.x*scale*zoom,box.y+box.h/2-v.y*scale*zoom) }
        switch scene.kind {
        case .particles:
            let model = try required(scene.particles)
            if simulation == nil || simulation!.frame>index { simulation = try .init(model) }
            while simulation!.frame<index { try simulation!.advance() }
            let s = min(box.w/model.width,box.h/model.height),x = box.x+(box.w-model.width*s)/2,y = box.y+(box.h-model.height*s)/2
            shapes += [line(x,y,x+model.width*s,y),line(x,y,x,y+model.height*s),line(x+model.width*s,y,x+model.width*s,y+model.height*s),line(x,y+model.height*s,x+model.width*s,y+model.height*s)]
            for (i,p) in simulation!.particles.enumerated() { shapes.append(circle(x+p.x*s,y+(model.height-p.y)*s,model.radius*s,i%2==0 ? .sage:.oat)) }
            labels.append(.init(text: "Equal masses · g = \(model.gravity) · restitution = \(model.restitution)",x: box.x,y: box.y+box.h+height*0.025,size: height*0.025))
        case .molecule:
            let model = try required(scene.molecule)
            let center = GraphicVector(x: (model.atoms.map { $0.position.x }.min()!+model.atoms.map { $0.position.x }.max()!)/2,y: (model.atoms.map { $0.position.y }.min()!+model.atoms.map { $0.position.y }.max()!)/2,z: (model.atoms.map { $0.position.z }.min()!+model.atoms.map { $0.position.z }.max()!)/2)
            let centered = Dictionary(uniqueKeysWithValues: model.atoms.map { ($0.id,GraphicVector(x: $0.position.x-center.x,y: $0.position.y-center.y,z: $0.position.z-center.z)) })
            let vectors = centered.mapValues { rotate($0,time*model.spinRadiansPerSecond) }
            let extent = max(1,model.atoms.map { let p = centered[$0.id]!;return sqrt(p.x*p.x+p.y*p.y+p.z*p.z)+$0.radius }.max() ?? 1),zoom = 2.4/extent
            for bond in model.bonds {
                let a = projected(vectors[bond.first]!,zoom),b = projected(vectors[bond.second]!,zoom),delta = b-a,length = max(1,simd_length(delta)),normal = SIMD2(-delta.y/length,delta.x/length)
                for n in 0..<bond.order { let shift = (Double(n)-Double(bond.order-1)/2)*width*0.004;let p = a+normal*shift,q = b+normal*shift;shapes.append(line(p.x,p.y,q.x,q.y,.sage,4)) }
            }
            for atom in model.atoms.sorted(by: { vectors[$0.id]!.z < vectors[$1.id]!.z }) {
                let p = projected(vectors[atom.id]!,zoom);shapes.append(circle(p.x,p.y,atom.radius*scale*zoom,atom.color))
                labels.append(.init(text: atom.element,x: p.x-atom.radius*scale*zoom*0.4,y: p.y-atom.radius*scale*zoom*0.4,size: max(10,atom.radius*scale*zoom*0.8),color: atom.color.r*0.2126+atom.color.g*0.7152+atom.color.b*0.0722>0.6 ? .init(r: 0.12,g: 0.17,b: 0.14):.init(r: 0.98,g: 0.97,b: 0.93),plate: false))
            }
        case .atom:
            let model = try required(scene.atom),center = projected(.zero),r = model.orbitRadius*min(box.w/10,box.h/9)
            for orbit in 0..<3 {
                let angle = Double(orbit)*Double.pi/3
                func point(_ t: Double) -> SIMD2<Double> {
                    let x = cos(t)*r,y = sin(t)*r*0.38
                    return .init(center.x+x*cos(angle)-y*sin(angle),center.y+x*sin(angle)+y*cos(angle))
                }
                for n in 0..<32 { let a = point(Double(n)*Double.pi/16),b = point(Double(n+1)*Double.pi/16);shapes.append(line(a.x,a.y,b.x,b.y,.sage)) }
                let count = model.electronCount/3+(orbit<model.electronCount%3 ? 1:0)
                for n in 0..<count { let p = point(time*model.radiansPerSecond+Double(n)*Double.pi*2/Double(count));shapes.append(circle(p.x,p.y,max(3,scale*0.09),.sage)) }
            }
            shapes.append(circle(center.x,center.y,scale*0.36,.oat));labels.append(.init(text: "Z = \(model.protonCount) · \(model.electronCount) illustrative electrons",x: box.x,y: box.y+box.h+height*0.025,size: height*0.025))
        case .reaction:
            let model = try required(scene.reaction)
            func formula(_ terms: [ReactionGraphicTerm]) -> String { terms.map { term in (term.coefficient==1 ? "":"\(term.coefficient)")+term.atoms.keys.sorted().map { $0+(term.atoms[$0]==1 ? "":"\(term.atoms[$0]!)") }.joined() }.joined(separator: " + ") }
            let equation = formula(model.reactants)+" → "+formula(model.products)
            labels.append(.init(text: equation,x: box.x,y: box.y,size: height*0.05,requireFullText: true))
            func atoms(_ terms: [ReactionGraphicTerm]) -> [String] {
                terms.flatMap { term in (0..<term.coefficient).flatMap { _ in term.atoms.keys.sorted().flatMap { Array(repeating: $0,count: term.atoms[$0]!) } } }
            }
            let before = atoms(model.reactants),after = atoms(model.products)
            guard before.count<=96 else { throw WorkflowFailure.invalid("Use at most 96 displayed atoms in a reaction scene.") }
            let t = min(1,time/model.durationSeconds),mix = t*t*(3-2*t),columns = min(12,max(1,Int(ceil(sqrt(Double(before.count)*2)))))
            var destinations = Dictionary(grouping: after.indices,by: { after[$0] })
            for (i,element) in before.enumerated() {
                let j = destinations[element]!.removeFirst(),a = SIMD2(Double(i%columns),Double(i/columns)),b = SIMD2(Double(j%columns),Double(j/columns))
                let p = a*(1-mix)+b*mix,spacing = min(box.w/Double(columns+1),box.h/Double(max(2,(before.count+columns-1)/columns+2))),x = box.x+(p.x+1)*spacing,y = box.y+(p.y+1.5)*spacing
                let hue = element.utf8.reduce(0) { ($0+Int($1))%2 };shapes.append(circle(x,y,spacing*0.3,hue==0 ? .sage:.oat));labels.append(.init(text: element,x: x-spacing*0.12,y: y-spacing*0.12,size: max(10,spacing*0.22),color: hue==0 ? .init(r: 0.98,g: 0.97,b: 0.93):.init(r: 0.12,g: 0.17,b: 0.14),plate: false))
            }
            labels.append(.init(text: "Conserved typed atoms · illustrative rearrangement, not a reaction path",x: box.x,y: box.y+box.h+height*0.025,size: height*0.025))
        case .object:
            let model = try required(scene.object),center = model.center
            let centered = model.vertices.map { GraphicVector(x: $0.x-center.x,y: $0.y-center.y,z: $0.z-center.z) }
            let extent = max(0.001,centered.map { sqrt($0.x*$0.x+$0.y*$0.y+$0.z*$0.z) }.max() ?? 1),zoom = 2.4/extent
            let points = centered.map { rotate($0,0.6+time*model.spinRadiansPerSecond) }
            for triangle in model.triangles.sorted(by: { a,b in a.reduce(0) { $0+points[$1].z } < b.reduce(0) { $0+points[$1].z } }) {
                let p = points[triangle[0]],q = points[triangle[1]],r = points[triangle[2]],normal = simd_cross(q-p,r-p),length = simd_length(normal)
                guard length>1e-10 else { continue }
                let shade = 0.35+0.65*abs(simd_dot(normal/length,simd_normalize(SIMD3<Double>(0.3,0.8,1))))
                let color = GraphicColor(r: model.color.r*shade,g: model.color.g*shade,b: model.color.b*shade,a: model.color.a),a = projected(p,zoom),b = projected(q,zoom),c = projected(r,zoom)
                shapes.append(.triangle(.init(Float(a.x),Float(a.y)),.init(Float(b.x),Float(b.y)),.init(Float(c.x),Float(c.y)),color: color,depth: .init(Float(0.5-0.4*p.z/extent),Float(0.5-0.4*q.z/extent),Float(0.5-0.4*r.z/extent))))
            }
        case .market:
            let model = try required(scene.market),equilibrium = try model.equilibrium(at: time)
            func point(_ q: Double,_ p: Double) -> SIMD2<Double> { .init(box.x+q/model.maximumQuantity*box.w,box.y+box.h-p/model.maximumPrice*box.h) }
            shapes += [line(box.x,box.y,box.x,box.y+box.h),line(box.x,box.y+box.h,box.x+box.w,box.y+box.h)]
            for supply in [false,true] {
                let intercept = supply ? model.supplyIntercept:model.demandIntercept+model.demandShiftPerSecond*time,slope = supply ? model.supplySlope:-model.demandSlope
                var candidates = [(0.0,intercept),(model.maximumQuantity,intercept+slope*model.maximumQuantity),(-intercept/slope,0.0),((model.maximumPrice-intercept)/slope,model.maximumPrice)]
                candidates = candidates.filter { $0.0>=0 && $0.0<=model.maximumQuantity && $0.1>=0 && $0.1<=model.maximumPrice }.sorted { $0.0<$1.0 }
                if let first = candidates.first,let last = candidates.last { let a = point(first.0,first.1),b = point(last.0,last.1);shapes.append(line(a.x,a.y,b.x,b.y,supply ? .sage:.oat,5)) }
            }
            let e = point(equilibrium.quantity,equilibrium.price);shapes.append(circle(e.x,e.y,max(4,width*0.007),.sage))
            labels += [.init(text: String(format: "Q* = %.3g · P* = %.3g",equilibrium.quantity,equilibrium.price),x: box.x+box.w*0.4,y: box.y,size: height*0.035),.init(text: "Quantity → · Price ↑ · green supply / oat demand",x: box.x,y: box.y+box.h+height*0.025,size: height*0.025)]
        }
        guard shapes.count<=256,shapes.allSatisfy(\.valid),labels.count<=100 else { throw WorkflowFailure.invalid("This scene exceeds the bounded graphics renderer. Reduce its displayed elements.") }
        return .init(primitives: shapes,annotations: labels)
    }
    private func required<T>(_ value: T?) throws -> T { guard let value else { throw ProjectFailure.invalidProject };return value }
}
