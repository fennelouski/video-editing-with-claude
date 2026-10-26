import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProjectCoverRecord: Codable,Equatable,Sendable {
    var projectID: UUID
    var filename: String
    var sha256: String
    var sourceSHA256: String
    var generator: String
    var prompt: String
    var created: Date
}
struct ProjectCoverPack: Codable,Sendable {
    var schemaVersion: Int
    var entries: [Entry]
    struct Entry: Codable,Sendable {
        var projectID: UUID
        var imagePath: String
        var sha256: String
        var generator: String
        var prompt: String
    }
}
actor ProjectCoverRepository {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("Clauto Editor/Project Covers")) { self.root = root }
    func save(_ source: URL,projectID: UUID,generator: String,prompt: String,expectedSHA256: String? = nil) throws -> ProjectCoverRecord {
        guard !generator.isEmpty,generator.utf8.count <= 200,prompt.utf8.count <= 8000 else { throw ProjectFailure.invalidProject }
        let access = source.startAccessingSecurityScopedResource();defer { if access { source.stopAccessingSecurityScopedResource() } }
        let input = try SourceRenderDirectory.open(source.deletingLastPathComponent())
        let bytes = try input.read(source.lastPathComponent,limit: 64*1024*1024),sourceSHA = TranscriptSourceMap.sha(bytes)
        guard expectedSHA256 == nil || expectedSHA256 == sourceSHA,
              let imageSource = CGImageSourceCreateWithData(bytes as CFData,nil),CGImageSourceGetCount(imageSource) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [String:Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0,height > 0,width <= 8192,height <= 8192,width*height <= 16_777_216,
              let image = CGImageSourceCreateImageAtIndex(imageSource,0,nil) else { throw WorkflowFailure.invalid("Choose a valid, single PNG, JPEG or HEIC illustration up to 16 megapixels. The existing cover was retained.") }
        let normalized = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(normalized,UTType.png.identifier as CFString,1,nil) else { throw ProjectFailure.invalidProject }
        CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination) else { throw ProjectFailure.invalidProject }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let folder = try SourceRenderDirectory.open(root).child(projectID.uuidString,create: true)
        let data = normalized as Data,sha = TranscriptSourceMap.sha(data),filename = sha+".png"
        if try CreativeAssetFiles.exists(filename,in: folder) { guard try folder.voiceHash(filename,limit: 64*1024*1024) == sha else { throw ProjectFailure.invalidProject } }
        else { try folder.writeNew(data,name: filename) }
        return .init(projectID: projectID,filename: filename,sha256: sha,sourceSHA256: sourceSHA,generator: generator,prompt: prompt,created: Date())
    }
    func thumbnail(_ record: ProjectCoverRecord) throws -> Data {
        guard record.filename == record.sha256+".png",TranscriptCatalog.isSHA(record.sha256) else { throw ProjectFailure.invalidProject }
        let directory = try SourceRenderDirectory.open(root).child(record.projectID.uuidString)
        let bytes = try directory.read(record.filename,limit: 64*1024*1024)
        guard TranscriptSourceMap.sha(bytes) == record.sha256,let source = CGImageSourceCreateWithData(bytes as CFData,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { throw ProjectFailure.invalidProject }
        let result = NSMutableData();guard let output = CGImageDestinationCreateWithData(result,UTType.png.identifier as CFString,1,nil) else { throw ProjectFailure.invalidProject }
        CGImageDestinationAddImage(output,image,nil);guard CGImageDestinationFinalize(output) else { throw ProjectFailure.invalidProject }
        return result as Data
    }
}
