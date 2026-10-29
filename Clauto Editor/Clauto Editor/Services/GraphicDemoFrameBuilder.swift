import Foundation
import simd

/// One fitted camera for the whole action prevents imported sizes or changing
/// silhouettes from causing frame-to-frame zoom. This is matte illustration;
/// light and an analytic contact shadow never pretend to be scanned texture.
struct GraphicDemoFrameBuilder: Sendable {
    private let rig: GraphicDemoRig
    private let mesh: GraphicMesh
    private let points: [SIMD3<Double>]
    private let width: Double
    private let height: Double
    private let frameCount: Int
    private let fit: Double
    private let extent: Double
    private let ground: Double
    init(scene: GraphicScene) throws {
        guard let rig = scene.demoRig,let mesh = scene.object else { throw ProjectFailure.invalidProject }
        try rig.validate();try mesh.validate()
        self.rig = rig;self.mesh = mesh;width = Double(scene.width);height = Double(scene.height);frameCount = scene.frameCount
        let center = mesh.center
        let centered = mesh.vertices.map { SIMD3($0.x-center.x,$0.y-center.y,$0.z-center.z) }
        let radius = max(1e-9,centered.map(simd_length).max() ?? 1)
        let normalized = centered.map { $0/radius }
        points = normalized;extent = 1;ground = normalized.map(\.y).min() ?? -1
        // Sample the entire bounded sweep, independent of requested preview frame.
        // Extra margin covers the interval between samples and step micro-jitter.
        var boundX = 0.0,boundY = 0.0
        for sample in 0...64 {
            let yaw = rig.yawRadians + (rig.action == .hold ? 0:rig.sweepRadians*(Double(sample)/64-0.5))
            for p in normalized {
                let q = Self.rotate(p,yaw: yaw,pitch: rig.pitchRadians)
                boundX = max(boundX,abs(q.x));boundY = max(boundY,abs(q.y))
            }
        }
        fit = min(width*0.35/max(0.01,boundX),height*0.245/max(0.01,boundY))
    }
    private static func rotate(_ p: SIMD3<Double>,yaw: Double,pitch: Double) -> SIMD3<Double> {
        let x = p.x*cos(yaw)+p.z*sin(yaw),z = -p.x*sin(yaw)+p.z*cos(yaw)
        return .init(x,p.y*cos(pitch)-z*sin(pitch),p.y*sin(pitch)+z*cos(pitch))
    }
    private func noise(_ step: Int,_ lane: UInt64) -> Double {
        var state = rig.seed &+ UInt64(step) &* 0x9e3779b97f4a7c15 &+ lane
        state = (state ^ (state >> 30)) &* 0xbf58476d1ce4e5b9
        state = (state ^ (state >> 27)) &* 0x94d049bb133111eb
        return Double((state ^ (state >> 31)) >> 11)/9007199254740992.0*2-1
    }
    func frame(_ index: Int) throws -> [GraphicPrimitiveGPU] {
        try Task.checkCancellation()
        let stepped = index/rig.stepFrames*rig.stepFrames
        let last = max(rig.stepFrames,(frameCount-1)/rig.stepFrames*rig.stepFrames)
        let t = min(1,Double(stepped)/Double(last)),ease = t*t*(3-2*t)
        let action: Double
        switch rig.action {
        case .hold:action = 0
        case .turntable:action = t-0.5
        case .rock:action = sin(t*Double.pi*2)*0.5
        case .reveal:action = ease-0.5
        }
        let step = stepped/rig.stepFrames
        let yaw = rig.yawRadians+rig.sweepRadians*action+noise(step,1)*0.004
        let pitch = rig.pitchRadians+noise(step,2)*0.003
        let dx = noise(step,3)*1.5*width/1920,dy = noise(step,4)*1.5*height/1080
        func project(_ p: SIMD3<Double>) -> SIMD2<Float> { .init(Float(width*0.5+p.x*fit+dx),Float(height*0.405-p.y*fit+dy)) }
        let transformed = points.map { Self.rotate($0,yaw: yaw,pitch: pitch) }
        let light = simd_normalize(SIMD3<Double>(-0.45,1.2,0.6))
        // A convex projected footprint is a deliberately bounded contact shadow.
        // Nested translucent silhouettes soften the edge without a texture asset.
        let shadow = Self.rounded(Self.hull(points.map { p -> SIMD2<Double> in
            let above = p.y-ground
            let floor = SIMD3(p.x+above*0.32,ground,p.z-above*0.22)
            let p = Self.rotate(floor,yaw: yaw,pitch: pitch)
            return .init(p.x,p.y)
        }))
        var shapes: [GraphicPrimitiveGPU] = []
        if shadow.count>=3 {
            let center = shadow.reduce(SIMD2<Double>.zero,+)/Double(shadow.count)
            for ring in stride(from: 10,through: 0,by: -1) {
                let grow = 1+Double(ring)*0.009
                let polygon = shadow.map { center+($0-center)*grow }
                let c = GraphicColor(r: 74.0/255,g: 60.0/255,b: 46.0/255,a: 0.021)
                for i in 1..<(polygon.count-1) {
                    func screen(_ p: SIMD2<Double>) -> SIMD2<Float> { project(.init(p.x,p.y,0)) }
                    shapes.append(.triangle(screen(polygon[0]),screen(polygon[i]),screen(polygon[i+1]),color: c))
                }
            }
        }
        let material = rig.material.baseColor
        let base = SIMD3(material.r,material.g,material.b)
        let sorted = mesh.triangles.enumerated().sorted { a,b in
            let az = a.element.reduce(0.0) { $0+transformed[$1].z },bz = b.element.reduce(0.0) { $0+transformed[$1].z }
            return az == bz ? a.offset<b.offset:az<bz
        }
        for item in sorted {
            let face = item.element,p = transformed[face[0]],q = transformed[face[1]],r = transformed[face[2]]
            var n = simd_normalize(simd_cross(q-p,r-p));if n.z<0 { n = -n }
            let key = max(0,simd_dot(n,light)),fill = max(0,simd_dot(n,simd_normalize(SIMD3<Double>(0.8,0.2,0.9))))
            let shade = rig.light == .warmSoft ? 0.42+0.60*key+0.08*fill:0.32+0.61*key+0.07*fill
            let color = GraphicColor(r: min(0.94,base.x*shade*1.035),g: base.y*shade,b: base.z*shade*0.965,a: mesh.color.a)
            func depth(_ p: SIMD3<Double>) -> Float { Float(0.5-p.z*0.4/extent) }
            shapes.append(.triangle(project(p),project(q),project(r),color: color,depth: .init(depth(p),depth(q),depth(r))))
        }
        return shapes
    }
    /// Two bounded corner-cut passes soften the analytic contact footprint while
    /// preserving its location and overall projection beneath the model.
    private static func rounded(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard input.count>=3 else { return input }
        var polygon = input
        for _ in 0..<2 {
            var next: [SIMD2<Double>] = [];next.reserveCapacity(polygon.count*2)
            for i in polygon.indices {
                let a = polygon[i],b = polygon[(i+1)%polygon.count]
                next += [a*0.75+b*0.25,a*0.25+b*0.75]
            }
            polygon = next
        }
        return polygon
    }
    private static func hull(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let sorted = input.sorted { $0.x == $1.x ? $0.y<$1.y:$0.x<$1.x }
        guard sorted.count>2 else { return sorted }
        func cross(_ a: SIMD2<Double>,_ b: SIMD2<Double>,_ c: SIMD2<Double>) -> Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        var lower: [SIMD2<Double>] = [],upper: [SIMD2<Double>] = []
        for p in sorted { while lower.count>=2 && cross(lower[lower.count-2],lower.last!,p)<=0 { lower.removeLast() };lower.append(p) }
        for p in sorted.reversed() { while upper.count>=2 && cross(upper[upper.count-2],upper.last!,p)<=0 { upper.removeLast() };upper.append(p) }
        lower.removeLast();upper.removeLast();return lower+upper
    }
}
