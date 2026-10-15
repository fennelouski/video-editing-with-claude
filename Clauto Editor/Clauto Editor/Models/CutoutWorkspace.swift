import Foundation

struct CutoutSourceInfo: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    let id: UUID
    let projectID: UUID
    let createdMilliseconds: Int64
    let name: String
    let encodedSHA256: String
    let rasterSHA256: String
    let orientation: Int
    let width: Int
    let height: Int
    let colorFormat: String
    func validate(project: UUID) throws {
        guard schemaVersion == 1, projectID == project, !name.isEmpty, name.utf8.count <= 512,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...8).contains(orientation), width > 0, height > 0, width <= 32_000, height <= 32_000,
              width*height <= 32_000_000, colorFormat == "Oriented straight sRGB RGBA8",
              Self.validHash(encodedSHA256), Self.validHash(rasterSHA256) else { throw CutoutFailure.changedSource }
    }
    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
struct CutoutDraft: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let assetID: UUID
    let projectID: UUID
    let sourceSHA256: String
    var generation: Int
    var basisID: UUID?
    var recipe: CutoutRecipe
    var currentRevisionID: UUID?
    func validate(source: CutoutSourceInfo) throws {
        guard schemaVersion == 1, assetID == source.id, projectID == source.projectID,
              sourceSHA256 == source.encodedSHA256, (0...1_000_000).contains(generation) else { throw CutoutFailure.invalidRecipe }
        try recipe.validate(width: source.width,height: source.height)
        guard recipe.manualMaskSHA256 == nil || recipe.selectedSubjects.isEmpty else { throw CutoutFailure.invalidMask }
        if basisID == nil, recipe.manualMaskSHA256 != nil || !recipe.selectedSubjects.isEmpty { throw CutoutFailure.invalidMask }
    }
}
struct CutoutDraftSnapshot: Equatable, Sendable {
    let source: CutoutSourceInfo
    let draft: CutoutDraft
    let savedSHA256: String
}
struct CutoutMaskBasis: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let id: UUID
    let sourceRasterSHA256: String
    let width: Int
    let height: Int
    let model: String
    let modelRevision: Int
    let subjectSHA256: [String:String]
    let manualSHA256: String?
    let manualSourceSHA256: String?
}
struct CutoutBasisPixels: Sendable {
    let manifest: CutoutMaskBasis
    let detection: CutoutDetection?
    let manual: Data?
}
struct CutoutExport: Sendable {
    let revision: CutoutAssetRevision
    let snapshot: CutoutDraftSnapshot
    let pngURL: URL
}
