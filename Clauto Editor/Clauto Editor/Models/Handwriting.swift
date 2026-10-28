import Foundation

enum HandwritingFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

struct HandwritingGenerationRequest: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var kind = "clauto.handwriting.generation-request"
    var requestID: String
    var exactText: String
    var exactTextUTF8SHA256: String
    var locale: String
    var prompt: String
    var requestedProvider = "Available user-authorized image generation tool"
    var transparentBackground = true
    var status = "awaitingProvider"
    var approval = "draft"
    var sourceStyleID: String?
    var providerBoundary = "Use available built-in imagegen skill, then import the actual result in Clauto. No live provider is embedded in the app."
    var capability = HandwritingRecipe.capability
    var nextAction = "Generate with an available supported tool; preserve original and receipt, then import with provider/model/requestID. Human spelling and alpha-edge approval required."
}

struct HandwritingProvenance: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case imported, aiGenerated, fixture }
    var kind: Kind = .imported
    var provider = "Local import"
    var model = "Not supplied"
    var prompt = ""
    var requestID = ""
    var sourceName = "artwork.png"
    var sourceSHA256 = ""
    func validate() throws {
        guard !provider.isEmpty, provider.utf8.count <= 512, model.utf8.count <= 512,
              prompt.utf8.count <= 16_384, requestID.utf8.count <= 512,
              !sourceName.isEmpty, sourceName.utf8.count <= 512,
              sourceSHA256.utf8.count == 64,
              sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HandwritingFailure.invalid("Supply the original image and complete, source-linked handwriting provenance.")
        }
        if kind == .aiGenerated, prompt.isEmpty || model.isEmpty || requestID.isEmpty {
            throw HandwritingFailure.invalid("AI artwork needs its exact prompt, provider model and generation request identifier.")
        }
    }
}

struct HandwritingExtraction: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case sourceAlpha, lightPaper, darkPaper }
    var mode: Mode = .sourceAlpha
    /// Ink coverage cutoff and transition width, both in normalized luminance.
    var threshold = 0.08
    var softness = 0.16
    /// Paper keying recovers edges into this declared ink color; original bytes stay saved.
    var inkRed: UInt8 = 74
    var inkGreen: UInt8 = 60
    var inkBlue: UInt8 = 46
    var cleanup: [CutoutBrushStroke] = []
    func validate(width: Int, height: Int) throws {
        guard threshold.isFinite, softness.isFinite, (0...0.95).contains(threshold),
              (0.001...1).contains(softness), cleanup.count <= 256,
              cleanup.reduce(0, { $0 + $1.points.count }) <= 8192 else {
            throw HandwritingFailure.invalid("Choose a finite paper-key threshold and softness, with at most 256 cleanup strokes.")
        }
        for stroke in cleanup { try stroke.validate(width: width, height: height) }
    }
}

struct HandwritingStroke: Codable, Equatable, Identifiable, Sendable {
    enum Easing: String, Codable, CaseIterable, Sendable { case linear, easeInOut }
    var id = UUID()
    var points: [CutoutPoint]
    /// Absolute integer frame onset. This explicitly represents pauses and overlaps.
    var startFrame = 0
    var durationFrames = 24
    /// Used by retimeInOrder(); render always obeys explicit startFrame.
    var pauseAfterFrames = 2
    var reverse = false
    var easing: Easing = .easeInOut
    var maskWidthPixels = 16.0
    func validate(frameCount: Int, width: Int, height: Int) throws {
        guard !points.isEmpty, points.count <= 4096, points.allSatisfy(\.valid),
              startFrame >= 0, startFrame < frameCount, startFrame % 2 == 0,
              durationFrames >= 2, durationFrames <= frameCount, durationFrames % 2 == 0,
              startFrame <= frameCount - durationFrames,
              pauseAfterFrames >= 0, pauseAfterFrames <= frameCount, pauseAfterFrames % 2 == 0,
              maskWidthPixels.isFinite, (0.5...Double(max(width, height) * 2)).contains(maskWidthPixels) else {
            throw HandwritingFailure.invalid("Each reveal path needs valid points, a positive brush width and even integer frame timing inside the animation.")
        }
    }
}

struct HandwritingRecipe: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var extraction = HandwritingExtraction()
    var strokes: [HandwritingStroke] = []
    var frameCount = 120
    static let capability = "Editable raster mask reveal approximation; not recorded or reconstructed pen strokes"
    static let rendererVersion = "clauto-handwriting-mask-1"
    func validate(width: Int, height: Int) throws {
        guard schemaVersion == 1, width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 4_000_000, (2...2400).contains(frameCount), frameCount % 2 == 0,
              strokes.count <= 512, Set(strokes.map(\.id)).count == strokes.count,
              strokes.reduce(0, { $0 + $1.points.count }) <= 16_384 else {
            throw HandwritingFailure.invalid("Handwriting supports at most 4 megapixels, 512 paths, 16,384 path points and 2–2400 even frames.")
        }
        try extraction.validate(width: width, height: height)
        for stroke in strokes { try stroke.validate(frameCount: frameCount, width: width, height: height) }
    }
    /// Reorder first, then call this to turn path pauses and an optional overlap into explicit onsets.
    mutating func retimeInOrder(overlapFrames: Int = 0) {
        let overlap = max(0, min(2400, overlapFrames / 2 * 2))
        var cursor = 0
        for index in strokes.indices {
            strokes[index].startFrame = cursor
            cursor = max(cursor, cursor + strokes[index].durationFrames + strokes[index].pauseAfterFrames - overlap)
        }
        let end = strokes.map { $0.startFrame + $0.durationFrames }.max() ?? 2
        frameCount = min(2400, max(2, end + 12))
    }
}

struct HandwritingReview: Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable { case draft, approved, rejected }
    var status: Status = .draft
    var liked = false
    var spellingChecked = false
    var alphaEdgesChecked = false
    var reviewer = ""
    var comments = ""
    var contexts: [String] = []
    func validate() throws {
        guard reviewer.utf8.count <= 256, comments.utf8.count <= 8192, contexts.count <= 32,
              contexts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 }) else {
            throw HandwritingFailure.invalid("Keep review notes within 8 KiB and supply at most 32 named use contexts.")
        }
        if status == .approved {
            guard liked, spellingChecked, alphaEdgesChecked,
                  !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !contexts.isEmpty else {
                throw HandwritingFailure.invalid("Approval needs an explicit like, spelling/diacritics and alpha-edge checks, reviewer, reasons and suitable contexts.")
            }
        }
        if status == .rejected, comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HandwritingFailure.invalid("Explain why this handwriting revision was rejected before saving it.")
        }
    }
    mutating func invalidateApproval() {
        status = .draft; spellingChecked = false; alphaEdgesChecked = false
    }
}

struct HandwritingDocument: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var revisionID = UUID()
    var parentRevisionID: UUID?
    var projectID: UUID
    var exactText: String
    var locale = "en"
    var provenance = HandwritingProvenance()
    var recipe = HandwritingRecipe()
    var review = HandwritingReview()
    var generationPrompt = ""
    // Swift String equality treats canonically equivalent Unicode sequences as
    // equal. Exact text/locale must also notice normalization-only revisions.
    static func == (lhs: Self,rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.id == rhs.id && lhs.revisionID == rhs.revisionID &&
        lhs.parentRevisionID == rhs.parentRevisionID && lhs.projectID == rhs.projectID &&
        lhs.exactText.utf8.elementsEqual(rhs.exactText.utf8) && lhs.locale.utf8.elementsEqual(rhs.locale.utf8) &&
        lhs.provenance == rhs.provenance && lhs.recipe == rhs.recipe && lhs.review == rhs.review &&
        lhs.generationPrompt.utf8.elementsEqual(rhs.generationPrompt.utf8)
    }
    func validate(width: Int, height: Int) throws {
        guard schemaVersion == 1, !exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              exactText.utf8.count <= 4096, !locale.isEmpty, locale.utf8.count <= 128,
              !locale.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              generationPrompt.utf8.count <= 16_384, parentRevisionID != revisionID else {
            throw HandwritingFailure.invalid("Supply exact text (up to 4 KiB), its locale and a distinct handwriting revision identifier.")
        }
        try provenance.validate(); try recipe.validate(width: width, height: height); try review.validate()
    }
}

struct HandwritingQuality: Codable, Equatable, Sendable {
    var inkPixels: Int
    var partialAlphaPixels: Int
    var boundaryInkPixels: Int
    var unrevealedPixels: Int
    var coverage: Double { inkPixels == 0 ? 0 : Double(inkPixels - unrevealedPixels) / Double(inkPixels) }
}

/// A preset captures user-approved settings and their reasons; drafts never enter discovery.
struct HandwritingStylePreset: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var name: String
    var sourceRevisionID: UUID
    var sourceAssetID: UUID
    var exactText: String
    var locale: String
    var sourceWidth: Int
    var sourceHeight: Int
    var recipe: HandwritingRecipe
    var review: HandwritingReview
    var provenance: HandwritingProvenance
    func validate() throws {
        guard schemaVersion == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 256, review.status == .approved, !exactText.isEmpty else {
            throw HandwritingFailure.invalid("Only explicitly approved handwriting revisions can become a named reusable style.")
        }
        try review.validate(); try provenance.validate()
        try recipe.validate(width: sourceWidth,height: sourceHeight)
    }
}
