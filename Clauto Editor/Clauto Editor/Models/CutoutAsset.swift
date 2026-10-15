import Foundation

struct CutoutRaster: Equatable, Sendable {
    let width: Int
    let height: Int
    /// Oriented, top-left row order, straight (not premultiplied) sRGB RGBA8.
    let rgba: Data
    func validate() throws {
        guard width > 0, height > 0, width <= 32_000, height <= 32_000,
              width*height <= 32_000_000, rgba.count == width*height*4 else { throw CutoutFailure.invalidImage }
    }
}

enum CutoutFailure: LocalizedError {
    case invalidImage, invalidMask, invalidRecipe, noSubject, changedSource, storageConflict, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Choose a supported image of at most 32 megapixels. Your original stays unchanged."
        case .invalidMask: "This mask does not match the image. Choose another mask or paint the subject."
        case .invalidRecipe: "This correction needs valid image points and a brush size. Your saved revision is preserved."
        case .noSubject: "The mask needs a subject and a clear background. Choose a subject or paint a correction."
        case .changedSource: "The source image changed. Choose the intended image to create a new revision."
        case .storageConflict: "This cutout changed in another window. Your correction is retained here."
        case .unavailable: "Local subject detection could not finish. Paint the subject to continue."
        }
    }
}

struct CutoutPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var valid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

struct CutoutBrushStroke: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, Sendable { case restore, erase }
    var id = UUID()
    var mode: Mode
    var radiusPixels: Double
    var points: [CutoutPoint]
    func validate(width: Int,height: Int) throws {
        guard radiusPixels.isFinite, (0.5...Double(max(width,height))).contains(radiusPixels),
              !points.isEmpty, points.count <= 1024, points.allSatisfy(\.valid) else { throw CutoutFailure.invalidRecipe }
    }
}

struct CutoutSubject: Equatable, Identifiable, Sendable {
    let id: Int
    let mask: Data
}

struct CutoutDetection: Equatable, Sendable {
    let width: Int
    let height: Int
    let subjects: [CutoutSubject]
    let model: String
    let modelRevision: Int
    func validate() throws {
        guard width > 0, height > 0, width <= 32_000, height <= 32_000, width*height <= 32_000_000,
              !subjects.isEmpty, subjects.count <= 32, subjects.count*width*height <= 64*1024*1024,
              Set(subjects.map(\.id)).count == subjects.count,
              subjects.allSatisfy({ $0.id > 0 && $0.mask.count == width*height }),
              !model.isEmpty, model.utf8.count <= 1024, modelRevision >= 0 else { throw CutoutFailure.invalidMask }
    }
}

protocol CutoutSubjectDetecting: Sendable {
    func detect(_ image: CutoutRaster) async throws -> CutoutDetection
}

struct CutoutRecipe: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var selectedSubjects: [Int] = []
    var strokes: [CutoutBrushStroke] = []
    var featherPixels = 0
    /// A supplied mask is a source-linked image, not generated artwork.
    var manualMaskSHA256: String?
    func validate(width: Int,height: Int) throws {
        guard schemaVersion == 1, selectedSubjects.count <= 32,
              Set(selectedSubjects).count == selectedSubjects.count, selectedSubjects.allSatisfy({ $0 > 0 }),
              strokes.count <= 512, strokes.reduce(0,{ $0+$1.points.count }) <= 16_384,
              (0...16).contains(featherPixels),
              manualMaskSHA256 == nil || (manualMaskSHA256!.utf8.count == 64 && manualMaskSHA256!.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) else { throw CutoutFailure.invalidRecipe }
        for stroke in strokes { try stroke.validate(width: width,height: height) }
    }
}

struct CutoutPixels: Equatable, Sendable {
    let image: CutoutRaster
    let mask: Data
    let foregroundPixels: Int
    let sourceRasterSHA256: String
    let recipeSHA256: String
}

struct CutoutAssetRevision: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let assetID: UUID
    let projectID: UUID
    let parentRevisionID: UUID?
    let created: Date
    let sourceName: String
    let sourceSHA256: String
    let sourceRasterSHA256: String
    let sourceOrientation: Int
    let width: Int
    let height: Int
    let recipeSHA256: String
    let imageSHA256: String
    let maskSHA256: String
    let model: String
    let modelRevision: Int
    let maskBasisID: UUID?
    let maskBasisSHA256: String?
    let foregroundPixels: Int
    let classification: String
    static let extractionClassification = "Local pixel extraction; not a scanned animation-variant set"
}
