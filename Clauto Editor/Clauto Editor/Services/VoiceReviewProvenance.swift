import Foundation
import CryptoKit
import Darwin

enum VoiceReviewProvenance {
    static func url(_ relative: String, project: Project) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.utf8.contains(0) else { throw ProjectFailure.invalidProject }
        let root = project.folder.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw ProjectFailure.invalidProject }; return url
    }
    private static func signature(_ info: stat) -> SourceFileSignature {
        .init(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
    static func inspect(_ relative: String, project: Project) throws -> VoiceArtifact {
        let file = try url(relative, project: project), fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw WorkflowFailure.invalid("The selected edit is missing or disconnected.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ProjectFailure.invalidProject }
        let before = signature(info); var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw WorkflowFailure.invalid("The selected edit could not be read completely.") }
            if n == 0 { break }; digest.update(data: Data(buffer.prefix(n)))
        }
        guard fstat(fd, &info) == 0, signature(info) == before,
              try url(relative, project: project) == file else { throw WorkflowFailure.invalid("The selected edit changed while its feedback identity was being verified.") }
        let result = VoiceArtifact(relativePath: relative, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), signature: before)
        try check(result, project: project); return result
    }
    static func check(_ artifact: VoiceArtifact, project: Project) throws {
        var info = stat(); let file = try url(artifact.relativePath, project: project)
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, signature(info) == artifact.signature else {
            throw WorkflowFailure.invalid("This saved version changed or disconnected. Voice feedback will not be reassigned to it.")
        }
    }
    static func check(_ target: VoiceReviewTarget, project: Project) throws {
        guard target.projectID == project.id else { throw ProjectFailure.invalidProject }
        try check(target.preview, project: project); try check(target.timeline, project: project)
        let folder = String(format: "cuts/v%03d/", target.versionNumber)
        guard try inspect(folder + "clauto-version.json", project: project).sha256 == target.versionMetadataSHA256,
              try inspect(target.approvedScriptPath, project: project).sha256 == target.approvedScriptSHA256,
              try inspect(target.approvedPlanPath, project: project).sha256 == target.approvedPlanSHA256,
              try inspect(folder + "inputs/brief.md", project: project).sha256 == target.approvedBriefSHA256 else { throw WorkflowFailure.invalid("The saved version's approved inputs changed. Resolve its provenance before preparing another candidate.") }
    }
}
