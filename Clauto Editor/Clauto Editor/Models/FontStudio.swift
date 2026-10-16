import Foundation

struct FontOutlinePoint: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
    var onCurve: Bool
    enum CodingKeys: String,CodingKey { case x,y; case onCurve = "on_curve" }
}
struct FontGlyphOutline: Codable, Equatable, Sendable {
    var advance: Int
    var contours: [[FontOutlinePoint]]
    func validate() throws {
        guard (0...4000).contains(advance), contours.count <= 256,
              contours.reduce(0,{ $0+$1.count }) <= 32768,
              contours.allSatisfy({ (3...8192).contains($0.count) && $0.allSatisfy({ (-4000...4000).contains($0.x) && (-4000...4000).contains($0.y) }) }) else { throw WorkflowFailure.invalid("This glyph needs valid contours and a width from 0 to 4000 font units.") }
    }
    var sha256: String { get throws { try validate(); return TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(self)) } }
}
enum FontGlyphOrigin: String,Codable,Sendable {
    case suppliedImage = "supplied_image", editedOutline = "edited_outline", generatedFallback = "generated_fallback"
    var label: String { switch self { case .suppliedImage:"Supplied image";case .editedOutline:"Edited outline";case .generatedFallback:"Generated from licensed Work Sans" } }
}
struct FontGlyph: Codable,Equatable,Identifiable,Sendable {
    var id: UUID
    var revisionID: UUID
    var scalar: Int
    var origin: FontGlyphOrigin
    var sourceID: UUID?
    var sourceFile: String
    var sourceSHA256: String
    var licenseSHA256: String?
    var rasterFile: String?
    var rasterSHA256: String?
    var outline: FontGlyphOutline
    var outlineSHA256: String
    var crop: [Double]?
    var baseline: Double?
    var inkThreshold: Double?
    var toleranceUnits: Double?
    var sidebearing: Double?
    var generation: String?
    enum CodingKeys: String,CodingKey {
        case id,scalar,origin,outline,crop,baseline,generation
        case revisionID = "revision_id",sourceID = "source_id",sourceFile = "source_file",sourceSHA256 = "source_sha256",licenseSHA256 = "license_sha256",outlineSHA256 = "outline_sha256"
        case rasterFile = "raster_file",rasterSHA256 = "raster_sha256"
        case inkThreshold = "ink_threshold",toleranceUnits = "tolerance_units",sidebearing
    }
    var character: String { UnicodeScalar(scalar).map(String.init) ?? "" }
    func validate() throws {
        guard (0x20...0x10FFFF).contains(scalar), !(0xD800...0xDFFF).contains(scalar),
              UnicodeScalar(scalar).map({ !CharacterSet.controlCharacters.contains($0) }) == true,
              CutoutSourceInfo.validHash(sourceSHA256), CutoutSourceInfo.validHash(outlineSHA256),
              try outline.sha256 == outlineSHA256 else { throw WorkflowFailure.invalid("A glyph mapping or outline changed without its source revision.") }
        if let crop {
            guard crop.count == 4, crop.allSatisfy({ $0.isFinite && (0...1).contains($0) }),crop[2]>0,crop[3]>0,crop[0]+crop[2]<=1+1e-12,crop[1]+crop[3]<=1+1e-12 else { throw CutoutFailure.invalidRecipe }
        }
        guard (rasterFile == nil) == (rasterSHA256 == nil) else { throw CutoutFailure.changedSource }
        if let rasterFile,let rasterSHA256 {
            guard let sourceID,rasterFile == sourceID.uuidString+"-raster.image",CutoutSourceInfo.validHash(rasterSHA256) else { throw CutoutFailure.changedSource }
        }
        if sourceFile == "fallback.ttf" {
            guard sourceID == nil, let licenseSHA256, CutoutSourceInfo.validHash(licenseSHA256),origin != .suppliedImage,rasterFile == nil else { throw WorkflowFailure.invalid("The generated fallback needs its licensed font source.") }
        } else {
            guard let sourceID, sourceFile == sourceID.uuidString+".image", origin != .generatedFallback,licenseSHA256 == nil else { throw WorkflowFailure.invalid("The supplied glyph needs its original image.") }
        }
    }
}
struct FontStudioSource: Codable,Equatable,Identifiable,Sendable {
    let id: UUID
    let name: String
    let sha256: String
    let width: Int
    let height: Int
    let orientation: Int
    var workingRasterSHA256: String?
    func validate() throws {
        guard !name.isEmpty,name.utf8.count <= 512,!name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              CutoutSourceInfo.validHash(sha256),workingRasterSHA256.map(CutoutSourceInfo.validHash) ?? true,
              width>0,height>0,width<=32000,height<=32000,width*height<=32_000_000,(1...8).contains(orientation) else { throw CutoutFailure.invalidImage }
    }
}
struct FontWorkspaceSummary: Identifiable,Sendable {
    let id: UUID
    let label: String
    let glyphCount: Int
}
struct FontStudioDraft: Codable,Equatable,Identifiable,Sendable {
    var schemaVersion = 1
    let id: UUID
    let projectID: UUID
    var generation: Int
    var label: String
    var sources: [FontStudioSource]
    var glyphs: [FontGlyph]
    var pendingMappings: [FontPendingMapping] = []
    var currentFontRevisionID: UUID?
    func validate() throws {
        guard schemaVersion == 1,(0...1_000_000).contains(generation),!label.isEmpty,label.utf8.count <= 128,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              sources.count <= 1024,glyphs.count <= 1024,Set(sources.map(\.id)).count == sources.count,
              Set(glyphs.map(\.id)).count == glyphs.count,Set(glyphs.map(\.scalar)).count == glyphs.count else { throw WorkflowFailure.invalid("This font needs a name and unique character mappings.") }
        for source in sources { try source.validate() }
        guard pendingMappings.count <= 1024,Set(pendingMappings.map(\.id)).count == pendingMappings.count else { throw WorkflowFailure.invalid("This font has too many pending character mappings.") }
        for mapping in pendingMappings {
            try mapping.validateDraft()
            if let sourceID = mapping.sourceID { guard sources.contains(where: { $0.id == sourceID }) else { throw CutoutFailure.changedSource } }
            if let target = mapping.replaceGlyphID { guard glyphs.contains(where: { $0.id == target }) else { throw ProjectFailure.invalidProject } }
        }
        guard glyphs.reduce(0,{ total,glyph in total+glyph.outline.contours.reduce(0,{ $0+$1.count }) }) <= 262144 else { throw WorkflowFailure.invalid("This font exceeds 262144 editable outline points. Split it into separate fonts to continue.") }
        for glyph in glyphs {
            try glyph.validate()
            if let sourceID = glyph.sourceID {
                guard sources.contains(where: { $0.id == sourceID && $0.sha256 == glyph.sourceSHA256 && (glyph.rasterSHA256 == nil || $0.workingRasterSHA256 == glyph.rasterSHA256) }) else { throw WorkflowFailure.invalid("The mapped glyph's original source is unavailable.") }
            }
        }
    }
}
struct FontDraftSnapshot: Equatable,Sendable {
    let draft: FontStudioDraft
    let savedSHA256: String
}
struct FontImageMapping: Codable,Equatable,Sendable {
    var scalar: Int
    var sourceFile: String
    var sourceSHA256: String
    var crop: [Double] = [0,0,1,1]
    var baseline = 0.8
    var inkThreshold = 0.55
    var toleranceUnits = 1.5
    var sidebearing = 55.0
    var rasterFile: String?
    var rasterSHA256: String?
    enum CodingKeys:String,CodingKey { case scalar,crop,baseline,sidebearing;case sourceFile = "source_file",sourceSHA256 = "source_sha256",inkThreshold = "ink_threshold",toleranceUnits = "tolerance_units",rasterFile = "raster_file",rasterSHA256 = "raster_sha256" }
}

extension FontGlyph {
    static func fromCompiler(_ bytes: Data,id: UUID = UUID(),sourceID: UUID?) throws -> FontGlyph {
        try TranscriptJSONKeys.validate(bytes)
        guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String:Any],object["schema_version"] as? Int == 1 else { throw ProjectFailure.invalidProject }
        object["id"] = id.uuidString; object["revision_id"] = UUID().uuidString
        if let sourceID { object["source_id"] = sourceID.uuidString }
        let value = try CreativeAssetFiles.decoder().decode(FontGlyph.self,from: JSONSerialization.data(withJSONObject: object,options: [.sortedKeys]))
        try value.validate(); return value
    }
}
enum FontCompilerRequest {
    static func data<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try CreativeAssetFiles.encoder().encode(value)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String:Any] else { throw ProjectFailure.invalidProject }
        object["schema_version"] = 1; return try JSONSerialization.data(withJSONObject: object,options: [.sortedKeys])
    }
    static func build(family: String,glyphs: [FontGlyph]) throws -> Data {
        guard !glyphs.isEmpty else { throw WorkflowFailure.invalid("Map at least one glyph before compiling this font.") }
        let encoded = try CreativeAssetFiles.encoder().encode(glyphs)
        let values = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: ["schema_version":1,"family":family,"glyphs":values],options: [.sortedKeys])
    }
}


/// Raw mapping fields autosave even while a number or character is incomplete.
/// Trace validates the complete values; it never discards partially typed input.
struct FontPendingMapping: Codable,Equatable,Identifiable,Sendable {
    var id = UUID()
    var sourceID: UUID?
    var character = ""
    var crop = ["0","0","1","1"]
    var baseline = "0.8"
    var threshold = "0.55"
    var replaceGlyphID: UUID?
    func validateDraft() throws {
        guard character.utf8.count <= 64,crop.count == 4,crop.allSatisfy({ $0.utf8.count <= 64 }),baseline.utf8.count <= 64,threshold.utf8.count <= 64 else { throw WorkflowFailure.invalid("Keep each mapping field within 64 bytes.") }
    }
    func scalar() throws -> Int {
        guard character.unicodeScalars.count == 1,let value = character.unicodeScalars.first,
              value.value >= 0x20,!CharacterSet.controlCharacters.contains(value) else { throw WorkflowFailure.invalid("Enter one printable Unicode character for this glyph.") }
        return Int(value.value)
    }
    func request(source: FontStudioSource) throws -> FontImageMapping {
        try validateDraft(); let values = crop.compactMap(Double.init)
        guard source.id == sourceID,values.count == 4,values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              values[2]>0,values[3]>0,values[0]+values[2]<=1+1e-12,values[1]+values[3]<=1+1e-12,
              let baseline = Double(baseline),baseline.isFinite,(0...1).contains(baseline),
              let threshold = Double(threshold),threshold.isFinite,(0.01...0.99).contains(threshold) else { throw WorkflowFailure.invalid("Choose a crop inside the oriented image, a baseline from 0 to 1 and an ink threshold from 0.01 to 0.99.") }
        return .init(scalar: try scalar(),sourceFile: source.id.uuidString+".image",sourceSHA256: source.sha256,crop: values,baseline: baseline,inkThreshold: threshold,rasterFile: source.workingRasterSHA256 == nil ? nil:source.id.uuidString+"-raster.image",rasterSHA256: source.workingRasterSHA256)
    }
}
extension FontGlyph {
    var provenanceLabel: String {
        if sourceID == nil,origin == .editedOutline { return "Edited generated fallback · licensed Work Sans" }
        return origin.label
    }
}
