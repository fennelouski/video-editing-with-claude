import Foundation

/// Only this generator can construct the in-memory QA permit. A JSON flag or a
/// fixture-looking pathname cannot admit an existing/private project to rendering.
/// Persisted manifests are evidence, not a way to mint a permit after restart.
struct SyntheticSourceSpanFixture: Sendable {
    let project: Project
    let fixtureID: UUID
    let projectIdentity: RenderDirectoryIdentity
    let manifestSHA256: String
    let catalogSHA256: String
    let manifest: SyntheticFixtureManifest
    var catalogURL: URL { project.folder.appendingPathComponent(manifest.catalogRelativePath) }
    private init(project: Project, fixtureID: UUID, projectIdentity: RenderDirectoryIdentity,
                 manifestSHA256: String, catalogSHA256: String, manifest: SyntheticFixtureManifest) {
        self.project = project; self.fixtureID = fixtureID; self.projectIdentity = projectIdentity
        self.manifestSHA256 = manifestSHA256; self.catalogSHA256 = catalogSHA256; self.manifest = manifest
    }

    static func generate(root: URL, engine: URL, runner: any CommandRunning = ProcessRunner()) async throws -> Self {
        let version = try String(contentsOf: engine.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try await ProjectRepository().create(name: "Synthetic source span QA", root: root, engine: engine, engineVersion: version)
        let owned = try SourceRenderDirectory.open(project.folder), metadata = try owned.child(".clauto")
        let originals = try owned.child("synthetic-originals", create: true, exclusive: true), fixtureID = UUID()
        let request: [String: Any] = ["schemaVersion": 1, "generator": "clauto-color-tone-v1", "fixtureID": fixtureID.uuidString,
            "projectPath": owned.url.path, "projectIdentity": ["device": owned.identity.device, "inode": owned.identity.inode],
            "stagingPath": originals.url.path, "stagingIdentity": ["device": originals.identity.device, "inode": originals.identity.inode]]
        let bytes = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let name = "source-span-generation-" + fixtureID.uuidString + ".json"
        try metadata.writeNew(bytes, name: name)
        let result = try await runner.run(ProcessCommand(executable: engine.appendingPathComponent("run"),
            arguments: ["render_transcript_spans.py", "--generate-fixture", metadata.url.appendingPathComponent(name).path,
                        "--input-sha256", TranscriptSourceMap.sha(bytes),
                        "--input-directory-device", String(metadata.identity.device), "--input-directory-inode", String(metadata.identity.inode)], directory: engine,
            environment: ["CLAUTO_OFFLINE": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"], timeout: .seconds(120)), onLine: nil)
        guard result.succeeded else { throw WorkflowFailure.invalid("Synthetic media generation failed: " + result.error + result.output) }
        try owned.checkPath(); try originals.checkPath()
        var sources: [TranscriptSource] = [], rows: [TranscriptRow] = [], inventory: [SyntheticFixtureSource] = []
        for id in ["a", "b"] {
            let media = try originals.read(id + ".mov"), mediaSHA = TranscriptSourceMap.sha(media)
            let indexes = id == "a" ? [(6,18,"Early synthetic tone."), (42,54,"Later synthetic tone.")] : [(24,36,"Middle synthetic tone.")]
            let words = indexes.map { TranscriptWord(word: $0.2, start: Double($0.0 * 1001) / 24000, end: Double($0.1 * 1001) / 24000) }
            let transcript = try JSONEncoder().encode(["words": words]), transcriptSHA = TranscriptSourceMap.sha(transcript)
            try originals.writeNew(transcript, name: id + ".words.json")
            let source = TranscriptSource(id: id, path: originals.url.appendingPathComponent(id + ".mov").path,
                sourceSHA256: mediaSHA, transcriptSHA256: transcriptSHA, duration: Double(72 * 1001) / 24000,
                words: words, originalTranscriptPath: originals.url.appendingPathComponent(id + ".words.json").path)
            sources.append(source)
            inventory.append(.init(sourceID: id, mediaRelativePath: "synthetic-originals/" + id + ".mov", sourceSHA256: mediaSHA,
                transcriptRelativePath: "synthetic-originals/" + id + ".words.json", transcriptSHA256: transcriptSHA, frames: 72))
            for (index, word) in words.enumerated() {
                rows.append(.init(id: id + String(format: "-w%05d-%05d-", index, index) + mediaSHA.prefix(8), sourceID: id,
                    sourceSHA256: mediaSHA, firstWord: index, lastWord: index, start: word.start, end: word.end,
                    inTimecode: "Synthetic frame \(indexes[index].0)", outTimecode: "Synthetic frame \(indexes[index].1)", text: word.word,
                    keep: true, notes: "Synthetic QA only", requestedGraphics: "", assistantGraphics: "", handwrittenAsset: "",
                    section: "Generated color and tone", uncertainty: "", originalOrder: rows.count + 1))
            }
        }
        let catalog = TranscriptCatalog(schemaVersion: 1, title: "Generated synthetic source span acceptance", datasetSHA256: TranscriptSourceMap.sha(Data(fixtureID.uuidString.utf8)), sources: sources, rows: rows)
        try catalog.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let catalogBytes = try encoder.encode(catalog), catalogSHA = TranscriptSourceMap.sha(catalogBytes)
        try originals.writeNew(catalogBytes, name: "catalog.json")
        let manifest = SyntheticFixtureManifest(schemaVersion: 1, generator: "clauto-color-tone-v1", projectID: project.id, fixtureID: fixtureID,
            catalogRelativePath: "synthetic-originals/catalog.json", catalogSHA256: catalogSHA, sources: inventory)
        let manifestBytes = try encoder.encode(manifest)
        try metadata.writeNew(manifestBytes, name: "source-span-synthetic-fixture.json")
        try owned.checkPath()
        return .init(project: project, fixtureID: fixtureID, projectIdentity: owned.identity,
            manifestSHA256: TranscriptSourceMap.sha(manifestBytes), catalogSHA256: catalogSHA, manifest: manifest)
    }

    func validate(map: TranscriptSourceMap, catalog: TranscriptCatalog) throws -> SourceRenderDirectory {
        let root = try SourceRenderDirectory.open(project.folder)
        guard root.identity == projectIdentity, map.projectID == project.id, map.catalogSHA256 == catalogSHA256 else { throw ProjectFailure.invalidProject }
        let metadata = try root.child(".clauto"), originals = try root.child("synthetic-originals")
        guard TranscriptSourceMap.sha(try metadata.read("source-span-synthetic-fixture.json")) == manifestSHA256,
              TranscriptSourceMap.sha(try originals.read("catalog.json")) == catalogSHA256,
              catalog.sources.count == manifest.sources.count else { throw WorkflowFailure.invalid("Generated fixture identity or exact source catalog changed.") }
        for source in catalog.sources {
            guard let expected = manifest.sources.first(where: { $0.sourceID == source.id }),
                  source.path == root.url.appendingPathComponent(expected.mediaRelativePath).path,
                  source.originalTranscriptPath == root.url.appendingPathComponent(expected.transcriptRelativePath).path,
                  source.sourceSHA256 == expected.sourceSHA256, source.transcriptSHA256 == expected.transcriptSHA256 else { throw ProjectFailure.invalidProject }
        }
        return root
    }
}
