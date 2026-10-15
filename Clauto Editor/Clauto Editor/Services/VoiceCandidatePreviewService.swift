import Foundation
import CryptoKit
import Darwin
import AVFoundation

enum VoiceMasterByteContract {
    static let sourceLimit: Int64 = 1_073_741_824
    static let outputLimit: Int64 = 8_589_934_592
    static let files = ["input.json", "candidate-plan.json", "candidate-approval.json", "parent.fcpxml", "source-map.json", "render-proof.json", "review.mov", "timeline.fcpxml"]
}
struct VoiceMasterProof: Codable, Sendable {
    let schemaVersion: Int
    let mode: String
    let productionAuthorized: Bool
    let appliedToWatchedVersion: Bool
    let inputSHA256: String
    let planSHA256: String
    let approvalSHA256: String
    let masterSHA256: String
    let masterBytes: Int64
    let readOnly: Bool
    let unlinked: Bool
    let snapshotIdentity: RenderDirectoryIdentity
    let width: Int
    let height: Int
    let channels: Int
    let peakNASBytesBudgeted: Int64
    let frames: Int
    let audioSamplesPerChannel: Int
    let fullDecodePassed: Bool
    let schemaChecked: Bool
    let fragments: [VoiceCandidateFragment]
    let artifactsSHA256: [String: String]
    let artifactSizes: [String: Int64]
}
private struct VoiceMasterRenderInput: Encodable {
    let mode = VoiceCandidateEditPlan.mode
    let productionAuthorized = false
    let projectPath: String
    let projectIdentity: RenderDirectoryIdentity
    let stagingPath: String
    let stagingIdentity: RenderDirectoryIdentity
    let snapshotPath: String
    let snapshotIdentity: RenderDirectoryIdentity
    let planSHA256: String
    let approvalSHA256: String
}

extension SourceRenderDirectory {
    private func voiceSignature(_ value: stat) -> SourceFileSignature {
        .init(device: value.st_dev,inode: value.st_ino,size: value.st_size,modifiedSeconds: Int64(value.st_mtimespec.tv_sec),modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),changedSeconds: Int64(value.st_ctimespec.tv_sec),changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
    /// Reads through the exact pinned descriptor, with a hard allocation bound.
    func voiceRead(_ name: String, matching artifact: VoiceArtifact, limit: Int) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.utf8.contains(0) else { throw ProjectFailure.invalidProject }
        let fd = openat(descriptor,name,O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProjectFailure.invalidProject }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit,
              voiceSignature(info) == artifact.signature else { throw ProjectFailure.invalidProject }
        var data = Data(), buffer = [UInt8](repeating: 0,count: 1024*1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd,&buffer,buffer.count)
            guard count >= 0 else { throw ProjectFailure.invalidProject }
            if count == 0 { break }
            guard data.count+count <= limit else { throw ProjectFailure.invalidProject }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd,&info) == 0, voiceSignature(info) == artifact.signature,
              fstatat(descriptor,name,&info,AT_SYMLINK_NOFOLLOW) == 0, voiceSignature(info) == artifact.signature,
              TranscriptSourceMap.sha(data) == artifact.sha256 else { throw ProjectFailure.invalidProject }
        try checkPath(); return data
    }
    func voiceInspect(_ name: String) throws -> VoiceArtifact {
        guard VoiceMasterByteContract.files.contains(name) else { throw ProjectFailure.invalidProject }
        var before = stat(), after = stat()
        guard fstatat(descriptor,name,&before,AT_SYMLINK_NOFOLLOW) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ProjectFailure.invalidProject }
        let sha = try voiceHash(name)
        guard fstatat(descriptor,name,&after,AT_SYMLINK_NOFOLLOW) == 0, voiceSignature(before) == voiceSignature(after) else { throw ProjectFailure.invalidProject }
        return .init(relativePath: name,sha256: sha,signature: voiceSignature(before))
    }
    func voiceCheck(_ artifact: VoiceArtifact) throws {
        guard VoiceMasterByteContract.files.contains(artifact.relativePath) else { throw ProjectFailure.invalidProject }
        var value = stat()
        guard fstatat(descriptor,artifact.relativePath,&value,AT_SYMLINK_NOFOLLOW) == 0, value.st_mode & S_IFMT == S_IFREG, voiceSignature(value) == artifact.signature else { throw WorkflowFailure.invalid("The candidate files changed before commit.") }
    }

    /// Separate streaming contract; does not raise the existing bounded Data reader.
    func voiceHash(_ name: String, limit: Int64 = VoiceMasterByteContract.outputLimit, copyTo destination: SourceRenderDirectory? = nil, destinationName: String? = nil) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw ProjectFailure.invalidProject }
        let fd = openat(descriptor,name,O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw WorkflowFailure.invalid("A candidate artifact is unavailable.") }; defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= limit else { throw WorkflowFailure.invalid("A candidate artifact exceeds its storage limit.") }
        let outputName = destinationName ?? name
        guard !outputName.isEmpty, outputName != ".", outputName != "..", !outputName.contains("/"), !outputName.utf8.contains(0) else { throw ProjectFailure.invalidProject }
        let output = destination.map { openat($0.descriptor,outputName,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,S_IRUSR | S_IWUSR) }
        if let output, output < 0 { throw WorkflowFailure.invalid("The candidate copy destination already exists or is unavailable.") }
        defer { if let output { Darwin.close(output) } }
        var digest = SHA256(), buffer = [UInt8](repeating: 0,count: 1024*1024), count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let n = Darwin.read(fd,&buffer,buffer.count)
            guard n >= 0 else { throw WorkflowFailure.invalid("Candidate streaming read failed.") }
            if n == 0 { break }; count += Int64(n)
            guard count <= limit && count <= before.st_size else { throw WorkflowFailure.invalid("A candidate artifact grew during verification.") }
            digest.update(data: Data(buffer.prefix(n)))
            if let output {
                try buffer.withUnsafeBytes { pointer in
                    var at = 0
                    while at < n { let written = Darwin.write(output,pointer.baseAddress!.advanced(by: at),n-at); guard written > 0 else { throw WorkflowFailure.invalid("Candidate streaming copy failed.") }; at += written }
                }
            }
        }
        if let output { guard fsync(output) == 0 else { throw WorkflowFailure.invalid("Candidate streaming copy could not be synced.") } }
        var after = stat(), path = stat()
        func unchanged(_ value: stat) -> Bool {
            value.st_dev == before.st_dev && value.st_ino == before.st_ino && value.st_size == before.st_size &&
            value.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec &&
            value.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        }
        guard count == before.st_size, fstat(fd,&after) == 0, fstatat(descriptor,name,&path,AT_SYMLINK_NOFOLLOW) == 0, unchanged(after), unchanged(path) else { throw WorkflowFailure.invalid("A candidate artifact changed during streaming verification.") }
        try checkPath(); try destination?.checkPath()
        return digest.finalize().map { String(format: "%02x",$0) }.joined()
    }
    func publishVoiceBundle(_ name: String, staging: SourceRenderDirectory, id: UUID) throws -> SourceRenderDirectory {
        try checkPath(); try staging.checkPath()
        guard staging.url.deletingLastPathComponent() == url, staging.url.lastPathComponent == name else { throw ProjectFailure.invalidProject }
        let destination = id.uuidString
        if renameatx_np(descriptor,name,descriptor,destination,UInt32(RENAME_EXCL)) == 0 {
            _ = fsync(descriptor)
            let final = try child(destination)
            guard final.identity == staging.identity else { throw ProjectFailure.invalidProject }; return final
        }
        guard errno == ENOTSUP else { throw WorkflowFailure.invalid("Candidate publication failed or its unique destination already exists.") }
        let final = try child(destination,create: true,exclusive: true)
        var total: Int64 = 0
        for file in VoiceMasterByteContract.files {
            var info = stat(); guard fstatat(staging.descriptor,file,&info,AT_SYMLINK_NOFOLLOW) == 0, info.st_size >= 0 else { throw ProjectFailure.invalidProject }
            total += info.st_size; guard total <= VoiceMasterByteContract.outputLimit else { throw ProjectFailure.invalidProject }
            let sha = try staging.voiceHash(file,copyTo: final)
            guard try final.voiceHash(file) == sha else { throw WorkflowFailure.invalid("The streamed NAS candidate copy changed.") }
        }
        guard fsync(final.descriptor) == 0 else { throw WorkflowFailure.invalid("The candidate directory could not be synced.") }
        return final
    }
}

enum VoiceCandidateRenderCheckpoint: Sendable { case inputFrozen, workerFinished, beforePublication }

actor VoiceCandidatePreviewService {
    private var running = false
    private let runner: any CommandRunning
    init(runner: any CommandRunning = ProcessRunner()) { self.runner = runner }
    func cancel() async { await runner.cancel() }
    func render(repository: VoiceReviewRepository, candidateID: UUID, engine: URL,
                onCheckpoint: (@Sendable (VoiceCandidateRenderCheckpoint, URL) async throws -> Void)? = nil,
                onLine: (@Sendable (ProcessLine) async -> Void)? = nil) async throws -> VoiceReviewDocument {
        guard !running else { throw WorkflowFailure.invalid("This project already has a candidate render in progress.") }; running = true
        defer { running = false }
        let snapshot = try await repository.approvedEditSnapshot(candidateID)
        guard snapshot.candidate.parent.preview.signature.size > 0, snapshot.candidate.parent.preview.signature.size <= VoiceMasterByteContract.sourceLimit, snapshot.candidate.parent.timeline.signature.size <= 16*1024*1024 else { throw WorkflowFailure.invalid("This review preview supports one watched movie up to 1 GiB. Its original remains unchanged.") }
        let project = repository.project
        let root = try SourceRenderDirectory.open(project.folder), output = try root.child("build").child("voice-candidates",create: true)
        let id = UUID(), name = ".pending-" + id.uuidString
        let staging = try output.child(name,create: true,exclusive: true)
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-voice-snapshot-"+id.uuidString)
        guard Darwin.mkdir(localURL.path,S_IRWXU) == 0 else { throw WorkflowFailure.invalid("The exclusive private snapshot directory could not be created.") }
        let local = try SourceRenderDirectory.open(localURL)
        defer {
            // Only remove this empty owned directory; never recursively remove paths.
            if (try? SourceRenderDirectory.open(localURL).identity) == local.identity { _ = Darwin.rmdir(localURL.path) }
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
            let plan = try encoder.encode(snapshot.plan), approval = try encoder.encode(snapshot.approval)
            guard TranscriptSourceMap.sha(plan) == snapshot.planSHA256, TranscriptSourceMap.sha(approval) == snapshot.approvalSHA256 else { throw ProjectFailure.invalidProject }
            try staging.writeNew(plan,name: "candidate-plan.json"); try staging.writeNew(approval,name: "candidate-approval.json")
            let parentURL = try VoiceReviewProvenance.url(snapshot.plan.parent.timeline.relativePath,project: project)
            let parentXML = try SourceRenderDirectory.open(parentURL.deletingLastPathComponent()).voiceRead(parentURL.lastPathComponent,matching: snapshot.plan.parent.timeline,limit: 16*1024*1024)
            guard TranscriptSourceMap.sha(parentXML) == snapshot.plan.parent.timeline.sha256 else { throw ProjectFailure.invalidProject }
            try staging.writeNew(parentXML,name: "parent.fcpxml")
            let input = VoiceMasterRenderInput(projectPath: root.url.path,projectIdentity: root.identity,stagingPath: staging.url.path,stagingIdentity: staging.identity,snapshotPath: local.url.path,snapshotIdentity: local.identity,planSHA256: snapshot.planSHA256,approvalSHA256: snapshot.approvalSHA256)
            let bytes = try encoder.encode(input), inputSHA = TranscriptSourceMap.sha(bytes)
            try staging.writeNew(bytes,name: "input.json")
            let workers = ["render_voice_candidate.py","render_transcript_spans.py"].map { engine.appendingPathComponent("scripts/"+$0) }
            let workerSHAs = try workers.map { TranscriptSourceMap.sha(try Data(contentsOf: $0)) }
            try await onCheckpoint?(.inputFrozen,staging.url)
            let result = try await runner.run(ProcessCommand(executable: engine.appendingPathComponent("run"),arguments: ["render_voice_candidate.py",staging.url.appendingPathComponent("input.json").path,"--input-sha256",inputSHA],directory: engine,environment: ["CLAUTO_OFFLINE":"1","HF_HUB_OFFLINE":"1"],timeout: .seconds(3600)),onLine: onLine)
            guard result.succeeded else { throw WorkflowFailure.invalid(result.cancelled ? "Candidate rendering cancelled. The watched version is unchanged." : "Candidate rendering failed. " + String((result.error+result.output).suffix(3000))) }
            try await onCheckpoint?(.workerFinished,staging.url)
            try Task.checkCancellation(); try root.checkPath(); try staging.checkPath(); try local.checkPath()
            guard try workers.map({ TranscriptSourceMap.sha(try Data(contentsOf: $0)) }) == workerSHAs else { throw WorkflowFailure.invalid("The candidate worker changed during rendering.") }
            let proofBytes = try staging.read("render-proof.json")
            let attestations = result.output.split(separator: "\n").compactMap { line -> [String:Any]? in
                guard let data = String(line).data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String:Any], value["phase"] as? String == "candidate_verified" else { return nil }
                return value
            }
            guard attestations.count == 1, attestations[0]["renderProofSHA256"] as? String == TranscriptSourceMap.sha(proofBytes) else { throw WorkflowFailure.invalid("The candidate receipt differs from the trusted worker's completed verification.") }
            try TranscriptJSONKeys.validate(proofBytes)
            let proof = try JSONDecoder().decode(VoiceMasterProof.self,from: proofBytes)
            let frames = snapshot.plan.fragments.reduce(0) { $0 + $1.frames }
            guard proof.schemaVersion == 1, proof.mode == VoiceCandidateEditPlan.mode, !proof.productionAuthorized, !proof.appliedToWatchedVersion,
                  proof.inputSHA256 == inputSHA, proof.planSHA256 == snapshot.planSHA256, proof.approvalSHA256 == snapshot.approvalSHA256,
                  proof.masterSHA256 == snapshot.plan.parent.preview.sha256, proof.masterBytes == snapshot.plan.parent.preview.signature.size,
                  proof.readOnly, proof.unlinked, proof.snapshotIdentity == local.identity, proof.fullDecodePassed, proof.width > 0, proof.width <= 3840, proof.height > 0, proof.height <= 2160, [1,2].contains(proof.channels),
                  proof.peakNASBytesBudgeted > 0, proof.peakNASBytesBudgeted <= VoiceMasterByteContract.outputLimit,
                  Set(proof.artifactSizes.keys) == Set(proof.artifactsSHA256.keys),
                  proof.fragments == snapshot.plan.fragments, proof.frames == frames, proof.audioSamplesPerChannel == frames*2002,
                  Set(proof.artifactsSHA256.keys) == Set(VoiceMasterByteContract.files.filter { !["input.json","render-proof.json"].contains($0) }),
                  proof.artifactSizes.values.allSatisfy({ $0 >= 0 && $0 <= VoiceMasterByteContract.outputLimit }), proof.artifactSizes.values.reduce(0,+) <= VoiceMasterByteContract.outputLimit else { throw WorkflowFailure.invalid("The candidate receipt does not bind the reviewed plan and immutable watched bytes.") }
            for (file,sha) in proof.artifactsSHA256 { guard try staging.voiceHash(file) == sha else { throw WorkflowFailure.invalid("A verified candidate artifact changed.") } }
            try validateTimeline(staging.read("timeline.fcpxml"),plan: snapshot.plan,project: project,proof: proof)
            let actual = try await AVURLAsset(url: staging.url.appendingPathComponent("review.mov")).load(.duration).seconds
            guard actual.isFinite, abs(actual-Double(frames*1001)/24000) <= 1.0/48000 else { throw WorkflowFailure.invalid("The actual candidate duration differs from its approved frame map.") }
            let expected = proof.artifactsSHA256.merging(["input.json":inputSHA,"render-proof.json":TranscriptSourceMap.sha(proofBytes)],uniquingKeysWith: { _,b in b })
            guard proof.artifactsSHA256["candidate-plan.json"] == snapshot.planSHA256,
                  proof.artifactsSHA256["candidate-approval.json"] == snapshot.approvalSHA256,
                  proof.artifactsSHA256["parent.fcpxml"] == snapshot.plan.parent.timeline.sha256 else { throw ProjectFailure.invalidProject }
            try validateLineage(staging.read("source-map.json"),plan: snapshot.plan)
            // Materialization and all large streaming reads occur outside the voice
            // ledger transaction so capture writes continue during NAS copying.
            try await onCheckpoint?(.beforePublication,staging.url)
            let final = try output.publishVoiceBundle(name,staging: staging,id: id)
            var receipts: [VoiceArtifact] = []
            for file in VoiceMasterByteContract.files {
                let receipt = try final.voiceInspect(file)
                guard receipt.sha256 == expected[file] else { throw ProjectFailure.invalidProject }
                if let size = proof.artifactSizes[file] { guard size == receipt.signature.size else { throw ProjectFailure.invalidProject } }
                receipts.append(receipt)
            }
            try validateLineage(final.read("source-map.json"),plan: snapshot.plan)
            try validateTimeline(final.read("timeline.fcpxml"),plan: snapshot.plan,project: project,proof: proof)
            return try await repository.commitPreview(snapshot,final: final,output: output,id: id,proof: proof,proofSHA: TranscriptSourceMap.sha(proofBytes),receipts: receipts)
        } catch {
            if let data = try? JSONSerialization.data(withJSONObject: ["state":"incomplete","detail":error.localizedDescription,"productionAuthorized":false]) { try? staging.writeNew(data,name: "failure.json") }
            throw error
        }
    }
    private func validateLineage(_ data: Data, plan: VoiceCandidateEditPlan) throws {
        try TranscriptJSONKeys.validate(data)
        let fragments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan.fragments))
        let expected: [String:Any] = ["mode":VoiceCandidateEditPlan.mode,"parentVersionID":plan.parent.versionID.uuidString,
            "parentNativeTimelineSHA256":plan.parent.timeline.sha256,"masterSHA256":plan.parent.preview.sha256,"fragments":fragments,
            "nativeCameraAndGraphicsLineage":"verbatim parent.fcpxml; reference only, not independently edited or revalidated",
            "canonicalVideo":"yuv420p8 decoded pixels","canonicalAudio":"48000 Hz signed 16-bit decoded PCM; no padding/resampling"]
        guard let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary, actual.isEqual(to: expected) else { throw WorkflowFailure.invalid("The candidate source lineage differs from its reviewed parent-frame map.") }
    }
    private func validateTimeline(_ data: Data, plan: VoiceCandidateEditPlan, project: Project, proof: VoiceMasterProof) throws {
        let doc = try XMLDocument(data: data,options: .nodeLoadExternalEntitiesNever)
        func children(_ node: XMLNode) -> [XMLElement] { (node.children ?? []).compactMap { $0 as? XMLElement } }
        func attrs(_ node: XMLElement) -> [String:String] { Dictionary(uniqueKeysWithValues: (node.attributes ?? []).map { ($0.name ?? "",$0.stringValue ?? "") }) }
        func time(_ frames: Int) -> String { let n=frames*1001, d=24000; func gcd(_ a: Int,_ b: Int) -> Int { b == 0 ? a : gcd(b,a%b) }; let g=gcd(n,d); return d/g == 1 ? "\(n/g)s" : "\(n/g)/\(d/g)s" }
        guard let root = doc.rootElement(), root.name == "fcpxml", attrs(root) == ["version":"1.13"] else { throw ProjectFailure.invalidProject }
        let top=children(root)
        guard top.count == 2, top[0].name == "resources", attrs(top[0]).isEmpty, top[1].name == "library", attrs(top[1]).isEmpty else { throw ProjectFailure.invalidProject }
        let resources=children(top[0])
        guard resources.count == 2, resources[0].name == "format", children(resources[0]).isEmpty,
              attrs(resources[0]) == ["id":"rFormat","frameDuration":time(1),"width":String(proof.width),"height":String(proof.height),"colorSpace":"1-1-1 (Rec. 709)"],
              resources[1].name == "asset", attrs(resources[1]) == ["id":"rMaster","name":"Exact watched master — review candidate","start":"0s","duration":time(plan.parentFrames),"hasVideo":"1","hasAudio":"1","format":"rFormat","audioSources":"1","audioChannels":String(proof.channels),"audioRate":"48000"] else { throw ProjectFailure.invalidProject }
        let reps=children(resources[1])
        guard reps.count == 1, reps[0].name == "media-rep", children(reps[0]).isEmpty,
              attrs(reps[0]) == ["kind":"original-media","src":try VoiceReviewProvenance.url(plan.parent.preview.relativePath,project: project).absoluteString] else { throw ProjectFailure.invalidProject }
        let events=children(top[1]);guard events.count == 1, events[0].name == "event", attrs(events[0]) == ["name":"Review candidates"] else { throw ProjectFailure.invalidProject }
        let projects=children(events[0]);guard projects.count == 1, projects[0].name == "project", attrs(projects[0]) == ["name":"Watched-master review candidate"] else { throw ProjectFailure.invalidProject }
        let sequences=children(projects[0]), total=plan.fragments.reduce(0,{$0+$1.frames})
        guard sequences.count == 1, sequences[0].name == "sequence", attrs(sequences[0]) == ["format":"rFormat","duration":time(total),"tcStart":"0s","tcFormat":"NDF","audioLayout":proof.channels == 1 ? "mono":"stereo","audioRate":"48k"] else { throw ProjectFailure.invalidProject }
        let spines=children(sequences[0]);guard spines.count == 1, spines[0].name == "spine", attrs(spines[0]).isEmpty else { throw ProjectFailure.invalidProject }
        let clips=children(spines[0]);guard clips.count == plan.fragments.count else { throw ProjectFailure.invalidProject }
        for (clip,f) in zip(clips,plan.fragments) {
            guard clip.name == "asset-clip", children(clip).isEmpty, attrs(clip) == ["name":f.id,"ref":"rMaster","offset":time(f.candidateStartFrame),"start":time(f.parentStartFrame),"duration":time(f.frames),"audioRole":"dialogue"] else { throw ProjectFailure.invalidProject }
        }
    }
}
