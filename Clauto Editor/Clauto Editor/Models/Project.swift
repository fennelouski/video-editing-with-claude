import Foundation

enum FileGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case footage = "Footage", audio = "Audio", music = "Music", graphics = "Graphics", scripts = "Scripts", other = "Other"
    var id: String { rawValue }
    var folder: String {
        switch self {
        case .footage: "footage/a-cam"
        case .audio: "footage/audio"
        case .music: "assets/music"
        case .graphics: "assets/graphics"
        case .scripts: "script"
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
}

struct ProjectManifest: Codable, Identifiable, Sendable {
    var schemaVersion = 1
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
}

struct Project: Identifiable, Sendable {
    var manifest: ProjectManifest
    var folder: URL
    var brief: Brief
    var id: UUID { manifest.id }
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
