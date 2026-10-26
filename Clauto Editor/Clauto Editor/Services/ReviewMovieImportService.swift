import Foundation
import AVFoundation

struct ReviewMovieImportRequest: Sendable {
    let movie: URL
    let movieSHA256: String
    let nativeTimeline: URL?
    let script: URL
    let plan: URL
    let brief: URL
    let verificationReceipt: URL
    let number: Int
    let label: String
}
/// Imports existing bytes into a new or explicitly selected existing project. This does not mint a
/// fresh script/plan/fact approval or admit camera originals to a renderer.
struct ReviewMovieImportService: Sendable {
    func importReview(_ request: ReviewMovieImportRequest, root projectRoot: URL, engine: URL, existingProject: Project? = nil,makeCurrent: Bool = false) async throws -> Project {
        guard (1..<1_000_000).contains(request.number), request.movie.pathExtension == "mp4", TranscriptCatalog.isSHA(request.movieSHA256) else { throw ProjectFailure.invalidProject }
        let source = try SourceRenderDirectory.open(request.movie.deletingLastPathComponent())
        let movieName = request.movie.lastPathComponent
        guard try source.voiceHash(movieName,limit: VoiceMasterByteContract.sourceLimit) == request.movieSHA256 else { throw WorkflowFailure.invalid("The selected movie does not match its verified receipt.") }
        let verification = try SourceRenderDirectory.open(request.verificationReceipt.deletingLastPathComponent()).read(request.verificationReceipt.lastPathComponent,limit: 1024*1024)
        try TranscriptJSONKeys.validate(verification)
        guard let receipt = try JSONSerialization.jsonObject(with: verification) as? [String:Any],
              receipt["sha256"] as? String == request.movieSHA256,
              let path = receipt["review"] as? String, URL(fileURLWithPath: path).resolvingSymlinksInPath() == request.movie.resolvingSymlinksInPath(),
              let passed = receipt["technical_checks_passed"] as? NSNumber, CFGetTypeID(passed) == CFBooleanGetTypeID(), passed.boolValue,
              let reportedDuration = receipt["duration_seconds"] as? Double, reportedDuration.isFinite,
              let reportedFrames = receipt["actual_frames"] as? Int, reportedFrames > 0, reportedFrames <= 86_400 else { throw WorkflowFailure.invalid("Choose the completed technical verification receipt for this exact watched movie. A planned or unverified render cannot be imported as verified.") }
        let tracks = try await AVURLAsset(url: request.movie).loadTracks(withMediaType: .video)
        guard tracks.count == 1 else { throw WorkflowFailure.invalid("Choose one verified video track.") }
        let videoRange = try await tracks[0].load(.timeRange)
        let avDuration = videoRange.duration.seconds
        let duration = Double(reportedFrames*1001)/24000
        let nominalRate = try await tracks[0].load(.nominalFrameRate)
        guard videoRange.start.seconds == 0 else { throw WorkflowFailure.invalid("Offset movie tracks require explicit timing support before review import.") }
        guard avDuration.isFinite, duration > 0, abs(duration-reportedDuration) <= 1.0/24000,
              abs(avDuration-duration) <= 1001.0/24000, abs(Double(nominalRate)-24000.0/1001) < 0.0001 else { throw WorkflowFailure.invalid("The verified movie has unsupported timing (\(nominalRate) fps; track \(avDuration)s; receipt \(reportedDuration)s for \(reportedFrames) frames).") }
        let version = try String(contentsOf: engine.appendingPathComponent("ENGINE_VERSION"),encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let project: Project
        if let existingProject {
            let reopened = try await ProjectRepository().open(existingProject.folder)
            guard reopened.id == existingProject.id,reopened.folderIdentity == existingProject.folderIdentity,reopened.manifest.engineVersion == version else { throw ProjectFailure.invalidProject }
            project = reopened
        } else { project = try await ProjectRepository().create(name: request.label+" review",root: projectRoot,engine: engine,engineVersion: version,importedReviewOnly: true) }
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let owned = lease.root,cuts = try owned.child("cuts")
        let versions = try FileManager.default.contentsOfDirectory(atPath: cuts.url.path).compactMap { name throws -> Int? in
            guard name.hasPrefix("v"),let number = Int(name.dropFirst()) else { return nil }
            guard (1..<1_000_000).contains(number) else { throw WorkflowFailure.invalid("This library has a cut version outside the supported range; no existing cut was replaced.") };return number
        }
        // Exact retries reuse a completed imported version. Never append the
        // same verified movie twice after an uncertain UI or transport result.
        for savedNumber in versions {
            let prior = try cuts.child(String(format: "v%03d",savedNumber))
            guard let data = try? prior.child("inputs").read("import-binding.json"),
                  let binding = try JSONSerialization.jsonObject(with: data) as? [String:Any],
                  binding["scope"] as? String == "review_existing_movie_only",
                  binding["movieSHA256"] as? String == request.movieSHA256 else { continue }
            let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(CutVersion.self,from: prior.read("clauto-version.json"))
            guard metadata.artifacts.contains("exports/"+movieName),
                  try prior.child("exports").voiceHash(movieName,limit: VoiceMasterByteContract.sourceLimit) == request.movieSHA256 else {
                throw WorkflowFailure.invalid("An earlier import of this movie is incomplete or changed. It was retained; no duplicate was appended.")
            }
            return project
        }
        let number = existingProject == nil ? request.number:max(request.number,(versions.max() ?? 0)+1)
        guard number < 1_000_000 else { throw ProjectFailure.invalidProject }
        let cut = try cuts.child(String(format: "v%03d",number),create: true,exclusive: true)
        let exports = try cut.child("exports",create: true), inputs = try cut.child("inputs",create: true), script = try inputs.child("script",create: true), plan = try cut.child("plan",create: true)
        let copiedSHA = try source.voiceHash(movieName,limit: VoiceMasterByteContract.sourceLimit,copyTo: exports)
        guard copiedSHA == request.movieSHA256, try exports.voiceHash(movieName,limit: VoiceMasterByteContract.sourceLimit) == copiedSHA else { throw ProjectFailure.invalidProject }
        func copy(_ url: URL, to destination: SourceRenderDirectory, as name: String, limit: Int64 = 16*1024*1024) throws -> String {
            let directory = try SourceRenderDirectory.open(url.deletingLastPathComponent())
            let sha = try directory.voiceHash(url.lastPathComponent,limit: limit,copyTo: destination,destinationName: name)
            guard try destination.voiceHash(name,limit: limit) == sha else { throw ProjectFailure.invalidProject }; return sha
        }
        let xmlSHA: String
        if let timeline = request.nativeTimeline { xmlSHA = try copy(timeline,to: exports,as: "watched.fcpxml") }
        else {
            let size = try await tracks[0].load(.naturalSize)
            guard size.width.isFinite,size.height.isFinite,size.width > 0,size.height > 0,size.width <= 16384,size.height <= 16384 else { throw ProjectFailure.invalidProject }
            let audio = try await AVURLAsset(url: request.movie).loadTracks(withMediaType: .audio)
            var channels = 0
            for track in audio {
                for format in try await track.load(.formatDescriptions) {
                    if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) { channels += Int(description.pointee.mChannelsPerFrame);break }
                }
            }
            guard channels <= 32 else { throw ProjectFailure.invalidProject }
            let xml = Data(Self.flatReviewXML(movie: exports.url.appendingPathComponent(movieName),frames: reportedFrames,width: Int(size.width),height: Int(size.height),audioSources: audio.count,audioChannels: channels).utf8)
            try exports.writeNew(xml,name: "watched.fcpxml");xmlSHA = TranscriptSourceMap.sha(xml)
        }
        let scriptName = request.script.lastPathComponent
        let scriptSHA = try copy(request.script,to: script,as: scriptName)
        let planSHA = try copy(request.plan,to: plan,as: "imported.plan.json")
        let briefSHA = try copy(request.brief,to: inputs,as: "brief.md")
        let receiptSHA = try copy(request.verificationReceipt,to: inputs,as: "original-verification.json")
        guard receiptSHA == TranscriptSourceMap.sha(verification) else { throw WorkflowFailure.invalid("The verification receipt changed during import.") }
        guard try source.voiceHash(movieName,limit: VoiceMasterByteContract.sourceLimit) == request.movieSHA256 else { throw WorkflowFailure.invalid("The original watched movie changed during import. The incomplete new project is retained as evidence.") }
        let snapshot = try JSONSerialization.data(withJSONObject: ["saved_sha256":xmlSHA,"source_sha256":xmlSHA,"scope":"imported_reference_only_no_new_production_approval"],options: [.sortedKeys])
        try exports.writeNew(snapshot,name: "watched.snapshot.json")
        let artifacts = ["exports/"+movieName,"exports/watched.fcpxml","exports/watched.snapshot.json","inputs/script/"+scriptName,"inputs/brief.md","inputs/original-verification.json","plan/imported.plan.json","inputs/import-binding.json"]
        let cutVersion = CutVersion(number: number,label: request.label+" · imported verified movie",engineVersion: version,runID: UUID(),artifacts: artifacts,approvedPlanHash: planSHA,briefHash: briefSHA,approvedScript: "inputs/script/"+scriptName)
        let binding: [String:Any] = ["schemaVersion":1,"scope":"review_existing_movie_only","projectID":project.id.uuidString,"versionID":cutVersion.id.uuidString,
            "originalMovie":request.movie.path,"movieSHA256":copiedSHA,"nativeTimelineSHA256":xmlSHA,"scriptSHA256":scriptSHA,"planSHA256":planSHA,"briefSHA256":briefSHA,"verificationReceiptSHA256":receiptSHA,
            "durationSeconds":duration,"actualAVTrackDurationSeconds":avDuration,"verifiedFrameCount":reportedFrames,"number":number,"originalVersionNumber":request.number,"originalsModified":false,"newEditorialApproval":false,"newFactApproval":false,"productionAuthorized":false,
            "candidateMode":VoiceCandidateEditPlan.mode,"timelineKind":request.nativeTimeline == nil ? "single_rendered_movie_reference":"imported_reference","originalSourceLayersEditable":false]
        try inputs.writeNew(JSONSerialization.data(withJSONObject: binding,options: [.sortedKeys]),name: "import-binding.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try cut.writeNew(encoder.encode(cutVersion),name: "clauto-version.json")
        let hasCurrent = try CreativeAssetFiles.exists("current.json",in: cuts)
        if existingProject == nil || !hasCurrent { try cuts.writeNew(encoder.encode(cutVersion.id),name: "current.json") }
        else if makeCurrent { try cuts.replacePointer(encoder.encode(cutVersion.id),name: "current.json") }
        try owned.checkPath(); try cut.checkPath(); return project
    }

    static func flatReviewXML(movie: URL,frames: Int,width: Int,height: Int,audioSources: Int = 0,audioChannels: Int = 0) -> String {
        let escaped = movie.absoluteString.replacingOccurrences(of: "&",with: "&amp;").replacingOccurrences(of: "\"",with: "&quot;")
        let duration = "\(frames*1001)/24000s"
        let audio = audioChannels > 0 ? " hasAudio=\"1\" audioSources=\"\(audioSources)\" audioChannels=\"\(audioChannels)\"":""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.13"><resources><format id="r1" width="\(width)" height="\(height)" frameDuration="1001/24000s" colorSpace="1-1-1 (Rec. 709)"/><asset id="r2" name="Rendered review (source layers not included)" start="0s" duration="\(duration)" hasVideo="1" format="r1"\(audio)><media-rep kind="original-media" src="\(escaped)"/></asset></resources><library><event name="Imported rendered reviews"><project name="Rendered review — original layers not included"><sequence format="r1" duration="\(duration)" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k"><spine><asset-clip ref="r2" offset="0s" start="0s" duration="\(duration)"/></spine></sequence></project></event></library></fcpxml>
        """
    }
}

/// Explicit review-only packet. Its project UUID must match the selected
/// project; paths are user-selected inputs, never instructions to execute.
struct ReviewMovieImportPacket: Decodable {
    let projectID: UUID
    let movie: URL
    let movieSHA256: String
    let nativeTimeline: URL?
    let script: URL
    let plan: URL
    let brief: URL
    let verificationReceipt: URL
    let number: Int
    let label: String
    var request: ReviewMovieImportRequest { .init(movie: movie,movieSHA256: movieSHA256,nativeTimeline: nativeTimeline,script: script,plan: plan,brief: brief,verificationReceipt: verificationReceipt,number: number,label: label) }
}
