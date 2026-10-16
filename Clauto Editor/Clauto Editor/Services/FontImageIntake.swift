import Foundation

/// Folder discovery stays off the main actor. Every selected file is read again
/// through the repository's no-follow reader before any project copy is made.
struct FontImageCandidate: Sendable {
    let url: URL
    let parentIdentity: RenderDirectoryIdentity
}
actor FontImageIntake {
    static let extensions: Set<String> = ["png","jpg","jpeg","tif","tiff","heic","heif"]
    func images(in selections: [URL]) throws -> [URL] { try candidates(in: selections).map(\.url) }
    func read(_ candidate: FontImageCandidate) throws -> Data {
        let parent = try SourceRenderDirectory.open(candidate.url.deletingLastPathComponent())
        guard parent.identity==candidate.parentIdentity else { throw WorkflowFailure.invalid("The selected image folder changed. Choose it again before importing.") }
        let bytes = try parent.read(candidate.url.lastPathComponent,limit: CutoutImageIO.sourceLimit)
        try parent.checkPath();return bytes
    }
    func candidates(in selections: [URL]) throws -> [FontImageCandidate] {
        guard !selections.isEmpty,selections.count <= 1024 else { throw WorkflowFailure.invalid("Choose up to 1024 images or folders.") }
        var found: [String:FontImageCandidate] = [:], visited = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.isPackageKey]
        func consider(_ url: URL) throws {
            try Task.checkCancellation();visited += 1
            guard visited <= 20000 else { throw WorkflowFailure.invalid("This selection contains over 20000 entries. Choose a smaller glyph folder.") }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { return }
            if values.isRegularFile == true,Self.extensions.contains(url.pathExtension.lowercased()) {
                // Canonicalize only the parent so /var and /private/var aliases
                // deduplicate without following a replacement leaf symlink.
                let owned = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
                let directory = try SourceRenderDirectory.open(owned.deletingLastPathComponent())
                found[owned.path] = .init(url: owned,parentIdentity: directory.identity)
                guard found.count <= 1024 else { throw WorkflowFailure.invalid("Choose a batch containing at most 1024 glyph images.") }
            }
        }
        for url in selections {
            try consider(url)
            let values = try url.resourceValues(forKeys: keys)
            guard values.isDirectory == true,values.isSymbolicLink != true,values.isPackage != true else { continue }
            var discoveryError: Error?
            guard let enumerator = FileManager.default.enumerator(at: url,includingPropertiesForKeys: Array(keys),options: [.skipsHiddenFiles,.skipsPackageDescendants],errorHandler: { _,error in discoveryError = error;return false }) else { throw ProjectFailure.invalidProject }
            while let item = enumerator.nextObject() as? URL { try consider(item) }
            if let discoveryError { throw discoveryError }
        }
        guard !found.isEmpty else { throw WorkflowFailure.invalid("Choose PNG, JPEG, TIFF or HEIC glyph images, or a folder containing them.") }
        return found.values.sorted { $0.url.path < $1.url.path }
    }
}
