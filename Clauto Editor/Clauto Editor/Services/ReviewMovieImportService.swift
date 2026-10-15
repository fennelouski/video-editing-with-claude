import Foundation
import AVFoundation

struct ReviewMovieImportRequest: Sendable {
    let movie: URL
    let movieSHA256: String
    let nativeTimeline: URL
    let script: URL
    let plan: URL
    let brief: URL
    let verificationReceipt: URL
    let number: Int
    let label: String
}
/// Imports existing bytes into a new review-only project. This does not mint a
/// fresh script/plan/fact approval or admit camera originals to a renderer.
struct ReviewMovieImportService: Sendable {
    func importReview(_ request: ReviewMovieImportRequest, root projectRoot: URL, engine: URL) async throws -> Project {
        guard request.number > 0, request.movie.pathExtension == "mp4", TranscriptCatalog.isSHA(request.movieSHA256) else { throw ProjectFailure.invalidProject }
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
              abs(avDuration-duration) <= 1001.0/24000, abs(Double(nominalRate)-24000.0/1001) < 0.0001 else { throw WorkflowFailure.invalid("The verified movie has an unsupported frame duration.") }
        let version = try String(contentsOf: engine.appendingPathComponent("ENGINE_VERSION"),encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try await ProjectRepository().create(name: request.label+" review",root: projectRoot,engine: engine,engineVersion: version,importedReviewOnly: true)
        let owned = try SourceRenderDirectory.open(project.folder), cut = try owned.child("cuts").child(String(format: "v%03d",request.number),create: true,exclusive: true)
        let exports = try cut.child("exports",create: true), inputs = try cut.child("inputs",create: true), script = try inputs.child("script",create: true), plan = try cut.child("plan",create: true)
        let copiedSHA = try source.voiceHash(movieName,limit: VoiceMasterByteContract.sourceLimit,copyTo: exports)
        guard copiedSHA == request.movieSHA256, try exports.voiceHash(movieName,limit: VoiceMasterByteContract.sourceLimit) == copiedSHA else { throw ProjectFailure.invalidProject }
        func copy(_ url: URL, to destination: SourceRenderDirectory, as name: String, limit: Int64 = 16*1024*1024) throws -> String {
            let directory = try SourceRenderDirectory.open(url.deletingLastPathComponent())
            let sha = try directory.voiceHash(url.lastPathComponent,limit: limit,copyTo: destination,destinationName: name)
            guard try destination.voiceHash(name,limit: limit) == sha else { throw ProjectFailure.invalidProject }; return sha
        }
        let xmlSHA = try copy(request.nativeTimeline,to: exports,as: "watched.fcpxml")
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
        let cutVersion = CutVersion(number: request.number,label: request.label+" · imported verified movie",engineVersion: version,runID: UUID(),artifacts: artifacts,approvedPlanHash: planSHA,briefHash: briefSHA,approvedScript: "inputs/script/"+scriptName)
        let binding: [String:Any] = ["schemaVersion":1,"scope":"review_existing_movie_only","projectID":project.id.uuidString,"versionID":cutVersion.id.uuidString,
            "originalMovie":request.movie.path,"movieSHA256":copiedSHA,"nativeTimelineSHA256":xmlSHA,"scriptSHA256":scriptSHA,"planSHA256":planSHA,"briefSHA256":briefSHA,"verificationReceiptSHA256":receiptSHA,
            "durationSeconds":duration,"actualAVTrackDurationSeconds":avDuration,"verifiedFrameCount":reportedFrames,"number":request.number,"originalsModified":false,"newEditorialApproval":false,"newFactApproval":false,"productionAuthorized":false,
            "candidateMode":VoiceCandidateEditPlan.mode]
        try inputs.writeNew(JSONSerialization.data(withJSONObject: binding,options: [.sortedKeys]),name: "import-binding.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try cut.writeNew(encoder.encode(cutVersion),name: "clauto-version.json")
        try owned.child("cuts").writeNew(encoder.encode(cutVersion.id),name: "current.json")
        try owned.checkPath(); try cut.checkPath(); return project
    }
}
