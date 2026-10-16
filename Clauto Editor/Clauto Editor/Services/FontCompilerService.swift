import Foundation

struct FontCompilerFiles: Sendable {
    let files: [String:Data]
    let scriptSHA256: String
    let dependenciesSHA256: [String:String]
    let requestSHA256: String
    let engineVersion: String
}
/// A fixed local font compiler. Input copies and generated outputs remain under
/// the project drive; the common mutation lease is released while Python runs.
actor FontCompilerService {
    private var busy = false
    private let makeRunner: @Sendable () -> any CommandRunning
    init(makeRunner: @escaping @Sendable () -> any CommandRunning = { ProcessRunner() }) { self.makeRunner = makeRunner }
    private struct Job: Sendable {
        let folder: URL
        let identity: RenderDirectoryIdentity
        let inputs: [String:String]
        let requestSHA256: String
    }
    private func prepare(_ project: Project,request: Data,inputs: [String:Data]) throws -> Job {
        guard request.count <= 16*1024*1024,inputs.count <= 2050,
              inputs.keys.allSatisfy(CreativeAssetFiles.validLeaf),inputs["request.json"] == nil,inputs["outputs"] == nil,
              inputs.values.allSatisfy({ !$0.isEmpty && $0.count <= 256*1024*1024 }),
              inputs.values.reduce(0,{ $0+$1.count }) <= 512*1024*1024 else { throw WorkflowFailure.invalid("This font job exceeds its local source limit.") }
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let folder = try lease.root.child(".clauto",create: true).child("font-jobs",create: true).child(UUID().uuidString,create: true,exclusive: true)
        for name in inputs.keys.sorted() { try Task.checkCancellation(); try folder.writeNew(inputs[name]!,name: name) }
        try folder.writeNew(request,name: "request.json"); try lease.validate(project); try folder.checkPath()
        return .init(folder: folder.url,identity: folder.identity,inputs: inputs.mapValues(TranscriptSourceMap.sha),requestSHA256: TranscriptSourceMap.sha(request))
    }
    private func outputs(_ project: Project,job: Job,names: [String]) throws -> [String:Data] {
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let folder = try lease.root.child(".clauto").child("font-jobs").child(job.folder.lastPathComponent)
        guard folder.identity == job.identity,TranscriptSourceMap.sha(try folder.read("request.json",limit: 16*1024*1024)) == job.requestSHA256 else { throw ProjectFailure.invalidProject }
        for (name,hash) in job.inputs {
            guard TranscriptSourceMap.sha(try folder.read(name,limit: 256*1024*1024)) == hash else { throw WorkflowFailure.invalid("A glyph source changed during compilation. Its previous font revision is preserved.") }
        }
        let result = try folder.child("outputs"); var files: [String:Data] = [:]
        for name in names { files[name] = try result.read(name,limit: 32*1024*1024) }
        try lease.validate(project); try folder.checkPath(); try result.checkPath(); return files
    }
    func execute(action: String,request: Data,inputs: [String:Data],project: Project,engine: URL,hasFallback: Bool = false) async throws -> FontCompilerFiles {
        guard ["trace","fallback","build"].contains(action),!busy else { throw WorkflowFailure.invalid("Font tools are busy. Your current mapping remains editable.") }
        busy = true; defer { busy = false }
        let engineDirectory = try SourceRenderDirectory.open(engine), tools = try engineDirectory.child("scripts").child("tools")
        let script = try tools.read("custom_font_studio.py",limit: 1024*1024), scriptHash = TranscriptSourceMap.sha(script)
        let dependencies = ["custom_font_studio.py":scriptHash,"trace.py":TranscriptSourceMap.sha(try tools.read("trace.py",limit: 1024*1024))]
        let versionBytes = try engineDirectory.read("ENGINE_VERSION",limit: 1024)
        guard let version = String(data: versionBytes,encoding: .utf8),!version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectFailure.invalidProject }
        let python = engineDirectory.url.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw WorkflowFailure.invalid("Choose the installed editing engine in Settings to prepare local font tools.") }
        let job = try prepare(project,request: request,inputs: inputs), runner = makeRunner()
        do {
            let result = try await runner.run(.init(executable: python,arguments: [tools.url.appendingPathComponent("custom_font_studio.py").path,action,job.folder.appendingPathComponent("request.json").path,job.folder.appendingPathComponent("outputs").path],directory: job.folder,environment: ["PYTHONDONTWRITEBYTECODE":"1"],timeout: .seconds(180)),onLine: nil)
            try Task.checkCancellation()
            guard result.succeeded else {
                let reason = result.error.split(separator: "\n").reversed().compactMap { line -> String? in
                    guard line.utf8.count<=8192,let data = String(line).data(using: .utf8),
                          let value = try? JSONSerialization.jsonObject(with: data) as? [String:Any],value["ok"] as? Bool == false,
                          let text = value["message"] as? String,!text.isEmpty,text.utf8.count<=512,
                          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
                    return text
                }.first
                throw WorkflowFailure.invalid((reason ?? "The local font could not be compiled.")+" Your mappings and earlier font revisions remain available for correction.")
            }
            try engineDirectory.checkPath(); try tools.checkPath()
            guard TranscriptSourceMap.sha(try tools.read("custom_font_studio.py",limit: 1024*1024)) == scriptHash,
                  try engineDirectory.read("ENGINE_VERSION",limit: 1024) == versionBytes else { throw WorkflowFailure.invalid("The local font tools changed during compilation. Retry with the intended engine revision.") }
            for (name,hash) in dependencies {
                guard TranscriptSourceMap.sha(try tools.read(name,limit: 1024*1024)) == hash else { throw WorkflowFailure.invalid("The font tracing tools changed. Retry with the intended engine revision.") }
            }
            let names = action == "build" ? ["font.ttf","font.woff2","manifest.json"]+(hasFallback ? ["OFL.txt"]:[]) : ["glyph.json"]+(action == "fallback" ? ["OFL.txt"]:[])
            return .init(files: try outputs(project,job: job,names: names),scriptSHA256: scriptHash,dependenciesSHA256: dependencies,requestSHA256: job.requestSHA256,engineVersion: version.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { await runner.cancel(); throw error }
    }
}
