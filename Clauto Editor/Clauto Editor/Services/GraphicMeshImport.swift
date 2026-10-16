import Foundation
import simd

enum GraphicMeshImport {
    /// An intentionally small OBJ geometry subset. Texture/material/file references
    /// cannot cause reads, downloads or execution; unsupported statements fail.
    static func parseOBJ(_ bytes: Data) throws -> GraphicMesh {
        guard !bytes.isEmpty,bytes.count<=1024*1024,let text = String(data: bytes,encoding: .utf8),!text.utf8.contains(0) else { throw WorkflowFailure.invalid("Choose a UTF-8 OBJ mesh smaller than 1 MiB.") }
        var vertices: [GraphicVector] = [],triangles: [[Int]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            let content = line.split(separator: "#",maxSplits: 1,omittingEmptySubsequences: false)[0],parts = content.split(whereSeparator: \.isWhitespace)
            guard let kind = parts.first else { continue }
            if kind == "v" {
                guard parts.count==4,vertices.count<512,let x = Double(parts[1]),let y = Double(parts[2]),let z = Double(parts[3]) else { throw WorkflowFailure.invalid("OBJ vertices need three finite coordinates; this editor supports at most 512 vertices.") }
                let v = GraphicVector(x: x,y: y,z: z);guard v.finite else { throw ProjectFailure.invalidProject };vertices.append(v)
            } else if kind == "f" {
                guard (4...17).contains(parts.count) else { throw WorkflowFailure.invalid("OBJ faces need 3–16 vertex indices.") }
                let indices = try parts.dropFirst().map { value -> Int in
                    guard !value.contains("/"),let number = Int(value),number != 0 else { throw WorkflowFailure.invalid("Use an OBJ with vertex-only faces. Texture and normal references are unsupported.") }
                    let index = number>0 ? number-1:vertices.count+number
                    guard vertices.indices.contains(index) else { throw ProjectFailure.invalidProject };return index
                }
                guard Set(indices).count==indices.count else { throw ProjectFailure.invalidProject }
                if indices.count>3 {
                    let points = indices.map { SIMD3(vertices[$0].x,vertices[$0].y,vertices[$0].z) },origin = points[0]
                    var normal = SIMD3<Double>.zero
                    for i in 1..<(points.count-1) { normal += simd_cross(points[i]-origin,points[i+1]-origin) }
                    let length = simd_length(normal);guard length>1e-10 else { throw ProjectFailure.invalidProject };normal /= length
                    let extent = max(1,points.map { simd_length($0-origin) }.max() ?? 1)
                    for i in points.indices {
                        let a = points[i],b = points[(i+1)%points.count],c = points[(i+2)%points.count]
                        guard abs(simd_dot(a-origin,normal))<=extent*1e-6,simd_dot(simd_cross(b-a,c-b),normal)>1e-10 else { throw WorkflowFailure.invalid("Use planar convex OBJ faces or triangulate the mesh before importing. Concave and folded faces are unsupported.") }
                    }
                }
                for i in 1..<(indices.count-1) { triangles.append([indices[0],indices[i],indices[i+1]]) }
                guard triangles.count<=128 else { throw WorkflowFailure.invalid("Choose a mesh with at most 128 triangulated faces.") }
            } else if kind == "o" || kind == "g" || kind == "s" { continue }
            else { throw WorkflowFailure.invalid("This OBJ uses unsupported statement \(kind). Export vertex-only geometry without materials or external references.") }
        }
        let mesh = GraphicMesh(vertices: vertices,triangles: triangles);try mesh.validate();return mesh
    }
}

actor GraphicMeshIntake {
    func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ProjectFailure.invalidProject }
        let parent = try SourceRenderDirectory.open(url.deletingLastPathComponent()),bytes = try parent.read(url.lastPathComponent,limit: 1024*1024)
        try parent.checkPath();return bytes
    }
}
