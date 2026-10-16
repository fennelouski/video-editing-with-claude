import Foundation
@preconcurrency import Metal
import simd

/// Exactly four aligned vectors; Metal consumes the same 64-byte layout.
struct GraphicPrimitiveGPU: Sendable {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var color: SIMD4<Float>
    var tags: SIMD4<UInt32>
    static func circle(x: Float,y: Float,radius: Float,color: GraphicColor) -> Self { .init(a: .init(x,y,radius,0),b: .zero,color: color.float,tags: .zero) }
    static func segment(x0: Float,y0: Float,x1: Float,y1: Float,width: Float,color: GraphicColor) -> Self { .init(a: .init(x0,y0,x1,y1),b: .init(width,0,0,0),color: color.float,tags: .init(1,0,0,0)) }
    static func triangle(_ p: SIMD2<Float>,_ q: SIMD2<Float>,_ r: SIMD2<Float>,color: GraphicColor,depth: SIMD3<Float>? = nil) -> Self { .init(a: .init(p.x,p.y,q.x,q.y),b: .init(r.x,r.y,depth?.x ?? 0,depth?.y ?? 0),color: color.float,tags: .init(2,depth?.z.bitPattern ?? 0,depth == nil ? 0:1,0)) }
    var valid: Bool {
        tags.x<=2 && tags.z<=1 && (tags.z==0 || (tags.x==2 && b.z>=0 && b.z<=1 && b.w>=0 && b.w<=1 && Float(bitPattern: tags.y).isFinite && (0...1).contains(Float(bitPattern: tags.y)))) && (tags.x != 0 || a.z>0) && (tags.x != 1 || b.x>0) && (0..<4).allSatisfy { a[$0].isFinite && b[$0].isFinite && color[$0].isFinite && abs(a[$0])<=1_000_000 && abs(b[$0])<=1_000_000 && (0...1).contains(color[$0]) }
    }
}
private final class GraphicGPUWorker: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLComputePipelineState
    let trianglePipeline: any MTLRenderPipelineState
    let triangleSamples: Int
    let depthState: any MTLDepthStencilState
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),let queue = device.makeCommandQueue() else { throw WorkflowFailure.invalid("A supported Metal GPU is unavailable for this graphics scene.") }
        let options = MTLCompileOptions(); options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.shader,options: options)
        guard let function = library.makeFunction(name: "clautoGraphicFrame") else { throw ProjectFailure.invalidProject }
        self.device = device; self.queue = queue; pipeline = try device.makeComputePipelineState(function: function)
        triangleSamples = device.supportsTextureSampleCount(4) ? 4:1
        let triangles = MTLRenderPipelineDescriptor()
        triangles.vertexFunction = library.makeFunction(name: "clautoTriangleVertex")
        triangles.fragmentFunction = library.makeFunction(name: "clautoTriangleColor")
        triangles.rasterSampleCount = triangleSamples;triangles.depthAttachmentPixelFormat = .depth32Float
        let depth = MTLDepthStencilDescriptor();depth.depthCompareFunction = .lessEqual;depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { throw ProjectFailure.invalidProject };self.depthState = depthState
        let color = triangles.colorAttachments[0]!
        color.pixelFormat = .rgba8Unorm;color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one;color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha;color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        trianglePipeline = try device.makeRenderPipelineState(descriptor: triangles)
    }
    func render(_ primitives: [GraphicPrimitiveGPU],width: Int,height: Int,job: FrameBlockingJob<CutoutRaster>) throws -> CutoutRaster {
        try job.checkCancellation()
        guard MemoryLayout<GraphicPrimitiveGPU>.stride==64,width>=1,height>=1,width<=7680,height<=7680,width*height<=8_388_608,
              primitives.count<=256,primitives.allSatisfy(\.valid) else { throw ProjectFailure.invalidProject }
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width: width,height: height,mipmapped: false)
        description.storageMode = .shared; description.usage = [.shaderWrite,.shaderRead,.renderTarget]
        let values = primitives.isEmpty ? [GraphicPrimitiveGPU(a: .zero,b: .zero,color: .zero,tags: .zero)]:primitives
        let buffer = values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!,length: $0.count,options: .storageModeShared) }
        guard let buffer,let texture = device.makeTexture(descriptor: description),let command = queue.makeCommandBuffer() else { throw WorkflowFailure.invalid("The GPU could not allocate this scene. Choose a smaller canvas and retry.") }
        let triangles = !primitives.isEmpty && primitives.allSatisfy { $0.tags.x==2 }
        if triangles {
            let pass = MTLRenderPassDescriptor(),attachment = pass.colorAttachments[0]!
            attachment.loadAction = .clear;attachment.clearColor = MTLClearColor(red: 0,green: 0,blue: 0,alpha: 0)
            if triangleSamples>1 {
                let multisample = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width: width,height: height,mipmapped: false)
                multisample.textureType = .type2DMultisample;multisample.sampleCount = triangleSamples;multisample.storageMode = .private;multisample.usage = .renderTarget
                guard let target = device.makeTexture(descriptor: multisample) else { throw ProjectFailure.invalidProject }
                attachment.texture = target;attachment.resolveTexture = texture;attachment.storeAction = .multisampleResolve
            } else { attachment.texture = texture;attachment.storeAction = .store }
            let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,width: width,height: height,mipmapped: false)
            depth.storageMode = .private;depth.usage = .renderTarget
            if triangleSamples>1 { depth.textureType = .type2DMultisample;depth.sampleCount = triangleSamples }
            guard let depthTexture = device.makeTexture(descriptor: depth) else { throw ProjectFailure.invalidProject }
            pass.depthAttachment.texture = depthTexture;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth = 1
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw ProjectFailure.invalidProject }
            var dimensions = SIMD2<UInt32>(UInt32(width),UInt32(height))
            encoder.setRenderPipelineState(trianglePipeline)
            if primitives.allSatisfy({ $0.color.w>=0.999 }) { encoder.setDepthStencilState(depthState) }
            encoder.setVertexBuffer(buffer,offset: 0,index: 0);encoder.setVertexBytes(&dimensions,length: MemoryLayout<SIMD2<UInt32>>.stride,index: 1)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: primitives.count*3);encoder.endEncoding()
        } else {
            guard let encoder = command.makeComputeCommandEncoder() else { throw ProjectFailure.invalidProject }
            var count = UInt32(primitives.count)
            encoder.setComputePipelineState(pipeline);encoder.setBuffer(buffer,offset: 0,index: 0);encoder.setBytes(&count,length: 4,index: 1);encoder.setTexture(texture,index: 0)
            let threads = MTLSize(width: pipeline.threadExecutionWidth,height: max(1,min(8,pipeline.maxTotalThreadsPerThreadgroup/pipeline.threadExecutionWidth)),depth: 1)
            encoder.dispatchThreads(.init(width: width,height: height,depth: 1),threadsPerThreadgroup: threads);encoder.endEncoding()
        }
        try job.checkCancellation();command.commit();command.waitUntilCompleted();try job.checkCancellation()
        guard command.status == .completed,command.error == nil else { throw WorkflowFailure.invalid("The GPU could not finish this frame. The previous exported scene remains available.") }
        var bytes = Data(count: width*height*4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow: width*4,from: MTLRegionMake2D(0,0,width,height),mipmapLevel: 0) }
        if triangles {
            bytes.withUnsafeMutableBytes { memory in
                let pixels = memory.bindMemory(to: UInt8.self)
                for i in stride(from: 0,to: pixels.count,by: 4) {
                    let alpha = Int(pixels[i+3]);if alpha>0 && alpha<255 { for channel in 0..<3 { pixels[i+channel] = UInt8(min(255,(Int(pixels[i+channel])*255+alpha/2)/alpha)) } }
                }
            }
        }
        try job.checkCancellation();return .init(width: width,height: height,rgba: bytes)
    }
    static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Primitive { float4 a; float4 b; float4 color; uint4 tags; };
    struct TriangleVertex { float4 position [[position]]; float4 color; };
    vertex TriangleVertex clautoTriangleVertex(const device Primitive *items [[buffer(0)]],constant uint2 &size [[buffer(1)]],uint index [[vertex_id]]) {
        Primitive item=items[index/3];uint corner=index%3;
        float2 point=corner==0 ? item.a.xy:(corner==1 ? item.a.zw:item.b.xy);
        TriangleVertex result;float z=item.tags.z==1 ? (corner==0 ? item.b.z:(corner==1 ? item.b.w:as_type<float>(item.tags.y))):0.0f;
        result.position=float4(point/float2(size)*float2(2.0f,-2.0f)+float2(-1.0f,1.0f),z,1.0f);result.color=item.color;return result;
    }
    fragment float4 clautoTriangleColor(TriangleVertex input [[stage_in]]) { return float4(input.color.rgb*input.color.a,input.color.a); }
    float segmentDistance(float2 p,float2 a,float2 b) {
        float2 v=b-a;float t=dot(v,v)>0 ? clamp(dot(p-a,v)/dot(v,v),0.0f,1.0f):0.0f;return length(p-a-t*v);
    }
    float cross2(float2 a,float2 b) { return a.x*b.y-a.y*b.x; }
    kernel void clautoGraphicFrame(const device Primitive *items [[buffer(0)]],constant uint &count [[buffer(1)]],texture2d<float,access::write> output [[texture(0)]],uint2 point [[thread_position_in_grid]]) {
        if(point.x>=output.get_width() || point.y>=output.get_height())return;
        float2 p=float2(point)+0.5f;float4 accumulated=0.0f;
        for(uint i=0;i<count;i++) {
            Primitive item=items[i];float distance=1000000.0f;
            if(item.tags.x==0) {
                if(any(abs(p-item.a.xy)>item.a.z+1.0f))continue;
                distance=length(p-item.a.xy)-item.a.z;
            } else if(item.tags.x==1) {
                float radius=item.b.x*0.5f;
                if(any(p<min(item.a.xy,item.a.zw)-radius-1.0f) || any(p>max(item.a.xy,item.a.zw)+radius+1.0f))continue;
                distance=segmentDistance(p,item.a.xy,item.a.zw)-radius;
            } else {
                float2 a=item.a.xy,b=item.a.zw,c=item.b.xy;
                if(any(p<min(a,min(b,c))-1.0f) || any(p>max(a,max(b,c))+1.0f))continue;
                if(abs(cross2(b-a,c-a))<0.000001f)continue;
                float3 e=float3(cross2(b-a,p-a),cross2(c-b,p-b),cross2(a-c,p-c));
                bool inside=all(e>=0.0f)||all(e<=0.0f);
                distance=min(segmentDistance(p,a,b),min(segmentDistance(p,b,c),segmentDistance(p,c,a)))*(inside ? -1.0f:1.0f);
            }
            float alpha=item.color.a*clamp(0.5f-distance,0.0f,1.0f);
            accumulated.rgb=item.color.rgb*alpha+accumulated.rgb*(1.0f-alpha);
            accumulated.a=alpha+accumulated.a*(1.0f-alpha);
        }
        if(accumulated.a>0.0f)accumulated.rgb/=accumulated.a;
        output.write(accumulated,point);
    }
    """#
}
/// Limits physical driver work even when a cancelled caller has already returned.
/// Waiting tasks hold no Dispatch worker; cancellation removes their admission.
final class GraphicBlockingExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let capacity: Int
    private var occupied = 0
    private var pending: [(UUID,@Sendable () -> Void)] = []
    init(label: String,capacity: Int = 2) {
        precondition((1...8).contains(capacity));self.capacity = capacity
        queue = DispatchQueue(label: label,qos: .userInitiated)
    }
    var inFlight: Int { lock.lock();defer { lock.unlock() };return occupied }
    var waiting: Int { lock.lock();defer { lock.unlock() };return pending.count }
    private func enqueue(_ id: UUID,work: @escaping @Sendable () -> Void) throws {
        lock.lock()
        if occupied<capacity { occupied += 1;lock.unlock();queue.async(execute: work) }
        else {
            guard pending.count<32 else { lock.unlock();throw WorkflowFailure.invalid("Several graphics jobs are waiting. Your scene is saved; retry after an earlier job finishes.") }
            pending.append((id,work));lock.unlock()
        }
    }
    private func cancel(_ id: UUID) { lock.lock();pending.removeAll { $0.0==id };lock.unlock() }
    private func finished() {
        lock.lock()
        if pending.isEmpty { occupied -= 1;lock.unlock() }
        else { let work = pending.removeFirst().1;lock.unlock();queue.async(execute: work) }
    }
    func perform<Value: Sendable>(_ work: @escaping @Sendable (FrameBlockingJob<Value>) throws -> Value) async throws -> Value {
        try Task.checkCancellation();let id = UUID(),job = FrameBlockingJob<Value>()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value,any Error>) in
                guard job.bind(continuation) else { return }
                do {
                    try job.checkCancellation()
                    try enqueue(id) {
                        defer { self.finished() }
                        do { try job.checkCancellation();let value = try work(job);try job.checkCancellation();job.finish(.success(value)) }
                        catch { job.finish(.failure(error)) }
                    }
                    // Cancellation can race admission. Remove a pending closure
                    // again after enqueue; admitted physical work checks the job.
                    do { try job.checkCancellation() } catch { cancel(id) }
                } catch { job.finish(.failure(error)) }
            }
        } onCancel: { self.cancel(id);job.cancel() }
        try Task.checkCancellation();return result
    }
}
actor GraphicMetalRenderer {
    static let implementationVersion = "Clauto Metal graphics 1"
    static var shaderSHA256: String { TranscriptSourceMap.sha(Data(GraphicGPUWorker.shader.utf8)) }
    private static let executor = GraphicBlockingExecutor(label: "com.clauto.graphics-gpu")
    private var worker: GraphicGPUWorker?
    func render(_ primitives: [GraphicPrimitiveGPU],width: Int,height: Int) async throws -> CutoutRaster {
        try Task.checkCancellation()
        guard MemoryLayout<GraphicPrimitiveGPU>.stride==64,width>=1,height>=1,width<=7680,height<=7680,width*height<=8_388_608,
              primitives.count<=256,primitives.allSatisfy(\.valid) else { throw ProjectFailure.invalidProject }
        let selected: GraphicGPUWorker
        if let worker { selected = worker }
        else {
            let prepared: GraphicGPUWorker = try await Self.executor.perform { job in
                try job.checkCancellation(); return try GraphicGPUWorker()
            }
            try Task.checkCancellation();if let worker { selected = worker } else { worker = prepared;selected = prepared }
        }
        return try await Self.executor.perform { job in
            try selected.render(primitives,width: width,height: height,job: job)
        }
    }
}
