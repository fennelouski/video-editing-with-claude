import Foundation

struct GraphicParticle: Equatable,Sendable {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
}
/// A reproducible, bounded illustration: equal masses, frictionless ideal disks,
/// constant gravity, fixed substeps and pair overlap correction. No fluid/thermal
/// or molecular claims are made by these trajectories.
struct GraphicParticleSimulation: Sendable {
    let model: ParticleGraphicModel
    private(set) var particles: [GraphicParticle]
    private(set) var frame = 0
    init(_ model: ParticleGraphicModel) throws {
        try model.validate();self.model = model
        var state = model.seed
        func random() -> Double { state ^= state << 13;state ^= state >> 7;state ^= state << 17;return Double(state>>11)/9007199254740992 }
        let columns = min(model.count,max(1,Int(ceil(sqrt(Double(model.count)*model.width/model.height))))),rows = (model.count+columns-1)/columns
        let dx = model.width/Double(columns),dy = model.height/Double(rows)
        guard min(dx,dy)>model.radius*2 else { throw WorkflowFailure.invalid("These disk sizes do not fit the starting grid. Reduce their count or radius.") }
        particles = (0..<model.count).map { index in
            let angle = random()*Double.pi*2
            return .init(x: (Double(index%columns)+0.5)*dx,y: (Double(index/columns)+0.5)*dy,vx: cos(angle)*model.speed,vy: sin(angle)*model.speed)
        }
    }
    var kineticEnergy: Double { particles.reduce(0) { $0+0.5*($1.vx*$1.vx+$1.vy*$1.vy) } }
    var mechanicalEnergy: Double { kineticEnergy-particles.reduce(0) { $0+model.gravity*$1.y } }
    mutating func advance() throws {
        try Task.checkCancellation();guard frame<2880 else { throw ProjectFailure.invalidProject }
        let dt = GraphicScene.frameDuration/10
        for _ in 0..<10 {
            for i in particles.indices {
                particles[i].x += particles[i].vx*dt
                particles[i].y += particles[i].vy*dt+0.5*model.gravity*dt*dt
                particles[i].vy += model.gravity*dt
            }
            for _ in 0..<2 {
                for i in particles.indices {
                    for j in particles.indices where j>i {
                        let dx = particles[j].x-particles[i].x,dy = particles[j].y-particles[i].y,d2 = dx*dx+dy*dy,diameter = model.radius*2
                        guard d2<diameter*diameter else { continue }
                        let distance = sqrt(max(d2,1e-20)),nx = d2>1e-20 ? dx/distance:1,ny = d2>1e-20 ? dy/distance:0
                        let correction = (diameter-distance)*0.5
                        particles[i].x -= nx*correction;particles[i].y -= ny*correction;particles[j].x += nx*correction;particles[j].y += ny*correction
                        let relative = (particles[j].vx-particles[i].vx)*nx+(particles[j].vy-particles[i].vy)*ny
                        if relative<0 {
                            let impulse = -(1+model.restitution)*relative*0.5
                            particles[i].vx -= impulse*nx;particles[i].vy -= impulse*ny;particles[j].vx += impulse*nx;particles[j].vy += impulse*ny
                        }
                    }
                }
                for i in particles.indices {
                    let r = model.radius
                    if particles[i].x<r { particles[i].x = r;if particles[i].vx<0 { particles[i].vx *= -model.restitution } }
                    if particles[i].x>model.width-r { particles[i].x = model.width-r;if particles[i].vx>0 { particles[i].vx *= -model.restitution } }
                    if particles[i].y<r { particles[i].y = r;if particles[i].vy<0 { particles[i].vy *= -model.restitution } }
                    if particles[i].y>model.height-r { particles[i].y = model.height-r;if particles[i].vy>0 { particles[i].vy *= -model.restitution } }
                }
            }
        }
        frame += 1
    }
}
