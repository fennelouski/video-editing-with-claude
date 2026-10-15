import Foundation
import CryptoKit

enum FileGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case footage = "Footage", audio = "Audio", music = "Music", graphics = "Graphics", scripts = "Scripts", creativeReferences = "Creative references", other = "Other"
    var id: String { rawValue }
    var folder: String {
        switch self {
        case .footage: "footage/a-cam"
        case .audio: "footage/audio"
        case .music: "assets/music"
        case .graphics: "assets/graphics"
        case .scripts: "script"
        case .creativeReferences: "notes/creative-references"
        case .other: "notes"
        }
    }
    static func classify(_ url: URL) -> FileGroup {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "avi", "mts", "m2ts", "mxf", "insv": .footage
        case "wav", "aif", "aiff", "mp3", "m4a", "flac": .audio
        case "png", "jpg", "jpeg", "heic", "tiff", "webp", "svg", "woff2", "ttf", "otf": .graphics
        case "txt", "md", "docx": .scripts
        default: .other
        }
    }
}

struct ProjectFile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var group: FileGroup
    var relativePath: String
    var originalPath: String
    var copied: Bool
    var needsRole: Bool
    var creativeReferenceRole: CreativeReference.Role? = nil
    var displayedGroup: FileGroup { creativeReferenceRole == nil ? group : .creativeReferences }
}

struct ProjectManifest: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var importedReviewOnly: Bool?
    var id = UUID()
    var name: String
    var aspect = "16:9"
    var engineVersion: String
    var claudeSessionID: UUID? = nil
    var created = Date()
    var modified = Date()
    var whisperModel = "large-v3"
    var files: [ProjectFile] = []
    var archived = false
    var durationBounds: VideoDurationBounds? = nil
    var exportResolution: ExportResolution? = nil
    var creativeReferences: [CreativeReference]? = nil
    var scriptSelection: ProjectScriptReference? = nil
    var requiresScriptSelection: Bool? = nil
    var mutationRevision: Int64? = nil
    var outputResolution: ExportResolution { exportResolution ?? .fullHD }
}

struct CreativeReference: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Hashable, Sendable { case styleGuide = "style_guide", tastePrinciples = "taste_principles" }
    var id: UUID
    var role: Role
    var name: String
    var relativePath: String
    var sha256: String
    var byteCount: Int
    var provenance: Provenance
    struct Provenance: Codable, Equatable, Sendable {
        var libraryFileID: String?
        var backingFileID: String?
        var version: Int?
        var originalPath: String
    }
}

struct CreativeReferenceImport: Sendable {
    var source: URL
    var role: CreativeReference.Role
    var expectedSHA256: String
    var provenance: CreativeReference.Provenance
    static func local(_ source: URL) throws -> Self {
        let role: CreativeReference.Role
        switch source.lastPathComponent.lowercased() {
        case "style_guide.md": role = .styleGuide
        case "taste_principles.md": role = .tastePrinciples
        default: throw WorkflowFailure.invalid("Choose style_guide.md or taste_principles.md for the project's creative references.")
        }
        let data = try Data(contentsOf: source)
        return .init(source: source, role: role,
            expectedSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            provenance: .init(libraryFileID: nil, backingFileID: nil, version: nil, originalPath: source.path))
    }
}

enum ExportResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd = "720p", fullHD = "1080p", ultraHD = "2160p"
    var id: String { rawValue }
    var shortEdge: Int { switch self { case .hd: 720; case .fullHD: 1080; case .ultraHD: 2160 } }
    var label: String { switch self { case .hd: "720p · HD"; case .fullHD: "1080p · Full HD"; case .ultraHD: "2160p · 4K" } }
    func dimensions(aspect: String) -> (width: Int, height: Int) {
        aspect == "9:16" ? (shortEdge, shortEdge * 16 / 9) : (shortEdge * 16 / 9, shortEdge)
    }
}

struct VideoDurationBounds: Codable, Equatable, Sendable {
    var minimum: Double? = nil
    var maximum: Double? = nil
    var enabled: Bool { minimum != nil || maximum != nil }

    func validate() throws {
        guard [minimum, maximum].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }),
              minimum == nil || maximum == nil || minimum! <= maximum! else {
            throw WorkflowFailure.invalid("Duration limits must be positive seconds, with the minimum no greater than the maximum.")
        }
    }

    func check(_ seconds: Double) throws {
        try validate()
        guard seconds.isFinite, seconds > 0 else { throw WorkflowFailure.invalid("The finished timeline has no verifiable duration.") }
        if let minimum, seconds < minimum - 1e-9 {
            throw WorkflowFailure.invalid(String(format: "Duration review required: the finished timeline is %.3fs, below the %.3fs minimum. Select complete narration or revise the limit. The previous cut stays current.", seconds, minimum))
        }
        if let maximum, seconds > maximum + 1e-9 {
            throw WorkflowFailure.invalid(String(format: "Duration review required: the finished timeline is %.3fs, above the %.3fs maximum. Review whole takes or sentences, or revise the limit. The previous cut stays current.", seconds, maximum))
        }
    }
}

struct Project: Identifiable, Sendable {
    var manifest: ProjectManifest
    var folder: URL
    var brief: Brief
    /// Captured for this open handle; filesystem identity is never exported or
    /// serialized into a portable project manifest.
    var folderIdentity: RenderDirectoryIdentity? = nil
    var id: UUID { manifest.id }
}

/// Keeps local Brief drafts separate from asynchronous disk acknowledgements.
/// Persisted revisions order manifest responses without relying on wall clocks.
struct ProjectPresentationState: Sendable {
    private struct Draft: Sendable { let token: UUID; let brief: Brief }
    private struct Key: Hashable, Sendable { let id: UUID; let root: String; let device: Int32?; let inode: UInt64? }
    private var drafts: [Key:Draft] = [:]
    private func key(_ project: Project) -> Key { .init(id: project.id,root: project.folder.resolvingSymlinksInPath().standardizedFileURL.path,device: project.folderIdentity?.device,inode: project.folderIdentity?.inode) }
    static func sameRoot(_ first: Project,_ second: Project) -> Bool {
        first.id == second.id && first.folder.resolvingSymlinksInPath().standardizedFileURL.path == second.folder.resolvingSymlinksInPath().standardizedFileURL.path && first.folderIdentity == second.folderIdentity
    }
    static func requireUnambiguousOpen(_ project: Project,among projects: [Project]) throws {
        guard !projects.contains(where: { $0.id == project.id && !sameRoot($0,project) }) else {
            throw WorkflowFailure.invalid("This copy shares its project ID with another folder already listed in Clauto. The requested copy was not opened; the current project folder is unchanged. Opening separate copies with the same ID is not supported yet.")
        }
    }
    var hasUnsavedBriefs: Bool { !drafts.isEmpty }
    func pendingBrief(for project: Project) -> Brief? { drafts[key(project)]?.brief }
    func requireCutInput(_ reopened: Project,chosen: Project) throws {
        guard Self.sameRoot(chosen,reopened) else {
            throw WorkflowFailure.invalid("The selected project folder changed before the cut could start. No run was prepared. Reopen the intended project before trying again.")
        }
        guard pendingBrief(for: chosen) == nil else {
            throw WorkflowFailure.invalid("Your latest Brief is still unsaved. No run was prepared. Save those changes before starting a cut.")
        }
    }
    mutating func submit(_ brief: Brief,for project: Project) -> UUID {
        let token = UUID(); drafts[key(project)] = .init(token: token,brief: brief); return token
    }
    @discardableResult mutating func acknowledge(_ token: UUID,for project: Project) -> Bool {
        let key = key(project)
        guard drafts[key]?.token == token else { return false }
        drafts.removeValue(forKey: key); return true
    }
    func present(_ incoming: Project,over current: Project?) -> Project {
        var next = incoming
        if let current, Self.sameRoot(current,incoming),
           (current.manifest.mutationRevision ?? 0) > (incoming.manifest.mutationRevision ?? 0) { next = current }
        if let draft = drafts[key(incoming)] { next.brief = draft.brief }
        return next
    }
}

struct Brief: Equatable, Sendable {
    var about = ""
    var audience = ""
    var length = ""
    var tone = ""
    var music = ""
    var graphics = ""
    var avoid = ""
    var script = ""

    var markdown: String {
        let sections = [("About", about), ("Audience", audience), ("Length", length), ("Tone", tone),
                        ("Music", music), ("Graphics", graphics), ("Avoid", avoid), ("Script", script)]
        return "# Video brief\n\n" + sections.map { section in
            let escaped = section.1.components(separatedBy: "\n").map { line in
                let heading = String(line.drop(while: { $0 == "\\" }))
                return sections.contains(where: { "## " + $0.0 == heading }) ? "\\" + line : line
            }.joined(separator: "\n")
            return "## \(section.0)\n\(escaped)"
        }.joined(separator: "\n\n") + "\n"
    }

    init() {}
    init(markdown: String) {
        let names = ["About", "Audience", "Length", "Tone", "Music", "Graphics", "Avoid", "Script"]
        var sections: [String: String] = [:], current: String?
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## "), names.contains(String(line.dropFirst(3))) {
                current = String(line.dropFirst(3)); sections[current!] = ""
            } else if let current {
                let heading = String(line.drop(while: { $0 == "\\" }))
                let decoded = line.hasPrefix("\\") && names.contains(String(heading.dropFirst(3))) && heading.hasPrefix("## ") ? String(line.dropFirst()) : line
                sections[current, default: ""] += decoded + "\n"
            }
        }
        let value: (String) -> String = { sections[$0, default: ""].trimmingCharacters(in: .newlines) }
        about = value("About"); audience = value("Audience"); length = value("Length"); tone = value("Tone")
        music = value("Music"); graphics = value("Graphics"); avoid = value("Avoid"); script = value("Script")
        if sections.isEmpty { about = markdown }
    }
}

enum ProjectFailure: LocalizedError {
    case invalidName, unavailableDrive, invalidProject, missingFile(String), unsupportedCamera
    var errorDescription: String? {
        switch self {
        case .invalidName: "Give the project a name without slashes or control characters."
        case .unavailableDrive: "The project drive is unavailable. Reconnect it and try again."
        case .invalidProject: "This project cannot be read safely. Choose its original project folder."
        case .missingFile(let name): "\(name) is unavailable. Reconnect its drive or choose the file again."
        case .unsupportedCamera: "Insta360 originals need a local Studio export before editing. Keep the originals and add the exported video."
        }
    }
}
