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
    static func fileSignature(_ relative: String,project: Project) throws -> SourceFileSignature {
        let file = try url(relative,project: project)
        var info = stat()
        guard lstat(file.path,&info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw WorkflowFailure.invalid("The watched movie is missing or disconnected.")
        }
        return signature(info)
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
        try check(target,project: project,ancestors: [])
    }
    private static func check(_ target: VoiceReviewTarget, project: Project, ancestors: Set<UUID>) throws {
        guard target.projectID == project.id else { throw ProjectFailure.invalidProject }
        guard !ancestors.contains(target.versionID), ancestors.count < 16 else {
            throw WorkflowFailure.invalid("This candidate's review lineage is cyclic or exceeds 16 generations. Keep this history and start a new saved version.")
        }
        try check(target.preview, project: project); try check(target.timeline, project: project)
        if let origin = target.candidateOrigin {
            let base = "build/voice-candidates/"+origin.renderID.uuidString+"/"
            guard target.id == origin.renderID, target.versionID == origin.renderID,
                  target.preview.relativePath == base+"review.mov", target.timeline.relativePath == base+"timeline.fcpxml" else { throw ProjectFailure.invalidProject }
            let folder = try SourceRenderDirectory.open(project.folder).child("build").child("voice-candidates").child(origin.renderID.uuidString)
            let completion = try folder.read("completion.json")
            guard TranscriptSourceMap.sha(completion) == target.versionMetadataSHA256 else { throw ProjectFailure.invalidProject }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let record = try decoder.decode(VoiceCandidatePreview.self,from: completion)
            guard record.id == origin.renderID, record.relativeFolder+"/" == base, record.folderIdentity == folder.identity,
                  record.completionSHA256 == nil, !record.productionAuthorized, !record.appliedToWatchedVersion,
                  record.frames > 0, record.frames <= 86_400,
                  target.duration == Double(record.frames)*1001/24000,
                  record.artifactsSHA256["review.mov"] == target.preview.sha256,
                  record.artifactsSHA256["timeline.fcpxml"] == target.timeline.sha256 else { throw ProjectFailure.invalidProject }
            let planBytes = try folder.read("candidate-plan.json"), approvalBytes = try folder.read("candidate-approval.json"), proofBytes = try folder.read("render-proof.json")
            guard TranscriptSourceMap.sha(planBytes) == record.planSHA256,
                  TranscriptSourceMap.sha(planBytes) == record.artifactsSHA256["candidate-plan.json"],
                  TranscriptSourceMap.sha(approvalBytes) == record.artifactsSHA256["candidate-approval.json"],
                  TranscriptSourceMap.sha(proofBytes) == record.proofSHA256 else { throw ProjectFailure.invalidProject }
            let plan = try decoder.decode(VoiceCandidateEditPlan.self,from: planBytes)
            let approval = try decoder.decode(VoiceCandidateEditApproval.self,from: approvalBytes)
            let proof = try decoder.decode(VoiceMasterProof.self,from: proofBytes)
            guard plan.candidateID == origin.candidateID, plan.mode == VoiceCandidateEditPlan.mode, plan.issues.isEmpty, !plan.productionAuthorized,
                  (plan.inheritedProtections ?? []) == (plan.parent.candidateOrigin?.protections ?? []),
                  (origin.protections ?? []) == (try VoiceProtectionConstraint.projected(through: plan)),
                  approval.id == record.approvalID, approval.planID == plan.id, approval.planSHA256 == record.planSHA256,
                  approval.scope == VoiceCandidateEditPlan.mode, !approval.productionAuthorized,
                  proof.planSHA256 == record.planSHA256, proof.approvalSHA256 == TranscriptSourceMap.sha(approvalBytes),
                  proof.masterSHA256 == plan.parent.preview.sha256, proof.fragments == plan.fragments,
                  proof.frames == record.frames, proof.fullDecodePassed, proof.schemaChecked,
                  !proof.productionAuthorized, !proof.appliedToWatchedVersion,
                  target.versionNumber == plan.parent.versionNumber, target.engineVersion == plan.parent.engineVersion,
                  target.approvedPlanPath == plan.parent.approvedPlanPath, target.approvedPlanSHA256 == plan.parent.approvedPlanSHA256,
                  target.approvedScriptPath == plan.parent.approvedScriptPath, target.approvedScriptSHA256 == plan.parent.approvedScriptSHA256,
                  target.approvedBriefSHA256 == plan.parent.approvedBriefSHA256 else { throw ProjectFailure.invalidProject }
            var chain = ancestors; chain.insert(target.versionID)
            try check(plan.parent,project: project,ancestors: chain)
            return
        }
        let folder = String(format: "cuts/v%03d/", target.versionNumber)
        guard try inspect(folder + "clauto-version.json", project: project).sha256 == target.versionMetadataSHA256,
              try inspect(target.approvedScriptPath, project: project).sha256 == target.approvedScriptSHA256,
              try inspect(target.approvedPlanPath, project: project).sha256 == target.approvedPlanSHA256,
              try inspect(folder + "inputs/brief.md", project: project).sha256 == target.approvedBriefSHA256 else { throw WorkflowFailure.invalid("The saved version's approved inputs changed. Resolve its provenance before preparing another candidate.") }
    }
}

/// Fast opening identity, captured before the decoder is created. Full hashing
/// stays in the asynchronous target preparation; both snapshots must agree.
struct ReviewMovieOpeningIdentity: Sendable {
    let relativePath: String
    let signature: SourceFileSignature
    static func capture(url: URL,project: Project) throws -> Self {
        let root = project.folder.standardizedFileURL.path+"/", path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw ProjectFailure.invalidProject }
        let relative = String(path.dropFirst(root.count))
        return .init(relativePath: relative,signature: try VoiceReviewProvenance.fileSignature(relative,project: project))
    }
    func check(_ target: VoiceReviewTarget,project: Project) throws {
        guard target.projectID == project.id, target.preview.relativePath == relativePath,
              target.preview.signature == signature,
              try VoiceReviewProvenance.fileSignature(relativePath,project: project) == signature else {
            throw WorkflowFailure.invalid("The movie changed while its player opened. Reopen the saved version before attaching feedback.")
        }
    }
}
