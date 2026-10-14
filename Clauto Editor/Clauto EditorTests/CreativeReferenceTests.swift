import Foundation
import Testing
import CryptoKit
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct CreativeReferenceTests {
    private func fixture() async throws -> (URL, URL, Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-references-\(UUID())")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"), withIntermediateDirectories: true)
        try "synthetic".write(to: engine.appendingPathComponent("ENGINE_VERSION"), atomically: true, encoding: .utf8)
        var project = try await ProjectRepository().create(name: "Synthetic", root: root, engine: engine, engineVersion: "synthetic")
        let clip = root.appendingPathComponent("clip.MOV"); try Data("synthetic source".utf8).write(to: clip)
        project = try await ProjectRepository().add([clip], to: project)
        try await ProjectRepository().approveScript("A complete synthetic sentence.", project: project)
        return (root, engine, project)
    }
    private func request(_ source: URL, _ text: String, _ role: CreativeReference.Role = .styleGuide) throws -> CreativeReferenceImport {
        let data = Data(text.utf8); try data.write(to: source)
        return .init(source: source, role: role,
            expectedSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            provenance: .init(libraryFileID: "synthetic-library", backingFileID: "synthetic-backing", version: 0, originalPath: source.path))
    }

    @Test func exactCreativeBytesAreProjectFilesWithoutBecomingNarration() async throws {
        let (root, _, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("style_guide.md")
        let input = try request(source, "# Synthetic style\n\nNo synthetic footage.\n")
        let repo = ProjectRepository()
        let attached = try await repo.addCreativeReferences([input], to: project)
        let again = try await repo.addCreativeReferences([input], to: attached)
        #expect(again.manifest.creativeReferences?.count == 1)
        let reference = try #require(again.manifest.creativeReferences?.first)
        #expect(reference.provenance.libraryFileID == "synthetic-library")
        #expect(reference.provenance.version == 0)
        #expect(again.manifest.files.contains { $0.id == reference.id && $0.group == .other && $0.displayedGroup == .creativeReferences })
        #expect(reference.relativePath.hasPrefix("notes/creative-references/"))
        #expect(try Data(contentsOf: again.folder.appendingPathComponent(reference.relativePath)) == Data(contentsOf: source))
        let altered = CreativeReferenceImport(source: source, role: .tastePrinciples, expectedSHA256: String(repeating: "0", count: 64), provenance: input.provenance)
        await #expect(throws: WorkflowFailure.self) { try await repo.addCreativeReferences([altered], to: again) }
        #expect(try await repo.open(again.folder).manifest.creativeReferences?.count == 1)
        var newVersion = input; newVersion.provenance.version = 1; newVersion.provenance.backingFileID = "synthetic-backing-v1"
        let versioned = try await repo.addCreativeReferences([newVersion], to: again)
        #expect(versioned.manifest.creativeReferences?.count == 2)
        #expect(versioned.manifest.creativeReferences?.last?.provenance.version == 1)
        let manifestURL = versioned.folder.appendingPathComponent("clauto-project.json")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        legacy.removeValue(forKey: "creativeReferences")
        var files = try #require(legacy["files"] as? [[String: Any]])
        for index in files.indices { files[index].removeValue(forKey: "creativeReferenceRole") }
        legacy["files"] = files
        try JSONSerialization.data(withJSONObject: legacy).write(to: manifestURL)
        #expect(try await repo.open(versioned.folder).manifest.creativeReferences?.count == 2)
        #expect(try await repo.creativeReferenceContext(project: versioned).count == 2)
        var wrongOrigin = input; wrongOrigin.provenance.originalPath = root.appendingPathComponent("unread-source.md").path
        await #expect(throws: WorkflowFailure.self) { try await repo.addCreativeReferences([wrongOrigin], to: versioned) }
    }

    @Test func runsFreezeReferenceVersionsAndRefuseTamperedCopies() async throws {
        let (root, engine, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository(), disk = WorkflowRepository()
        let source = root.appendingPathComponent("style_guide.md")
        let first = try request(source, "# First reference\nPreserve breaths.\n")
        var project = try await repo.addCreativeReferences([first], to: original)
        let run = try await disk.prepare(project: project, engine: engine, label: "First")
        let settings = try await disk.settings(run, project: project, engine: engine)
        let frozen = URL(fileURLWithPath: try #require(settings["style_guide"]))
        var cleared = run; cleared.creativeReferenceHashes = nil; cleared.creativeReferenceSnapshotSHA256 = nil
        var clearedSettings = settings
        for key in ["style_guide", "style_guide_sha256", "creative_reference_schema"] { clearedSettings.removeValue(forKey: key) }
        let pathsFile = run.folder.appendingPathComponent("paths.json")
        try JSONEncoder().encode(clearedSettings).write(to: pathsFile)
        await #expect(throws: WorkflowFailure.self) { try await disk.settings(cleared, project: project, engine: engine) }
        try JSONEncoder().encode(settings).write(to: pathsFile)
        let second = try request(source, "# Second reference\nPreserve complete sentences.\n")
        project = try await repo.addCreativeReferences([second], to: project)
        #expect(project.manifest.creativeReferences?.count == 2)
        #expect(try await disk.settings(run, project: project, engine: engine)["style_guide_sha256"] == first.expectedSHA256)
        let later = try await disk.prepare(project: project, engine: engine, label: "Second")
        #expect(try await disk.settings(later, project: project, engine: engine)["style_guide_sha256"] == second.expectedSHA256)
        try Data("changed frozen input".utf8).write(to: frozen)
        await #expect(throws: WorkflowFailure.self) { try await disk.settings(run, project: project, engine: engine) }
        let reference = try #require(project.manifest.creativeReferences?.last)
        try Data("changed project reference".utf8).write(to: project.folder.appendingPathComponent(reference.relativePath))
        await #expect(throws: WorkflowFailure.self) { try await repo.creativeReferenceContext(project: project) }
    }

    @Test func absentReferenceTailCannotHideASymlinkEscape() async throws {
        let (root, _, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let notes = project.folder.appendingPathComponent("notes")
        try FileManager.default.removeItem(at: notes)
        try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: outside)
        let source = root.appendingPathComponent("style_guide.md")
        let input = try request(source, "# Synthetic guide\nPreserve original bytes.\n")
        await #expect(throws: ProjectFailure.self) { try await ProjectRepository().addCreativeReferences([input], to: project) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try await ProjectRepository().open(project.folder).manifest.creativeReferences == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_CREATIVE_REFERENCE_PROJECT"] != nil))
    func importAuthorizedLibraryReferencesThroughActualRepository() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAUTO_CREATIVE_REFERENCE_PROJECT"]))
        let provenanceURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAUTO_CREATIVE_REFERENCE_PROVENANCE"]))
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [[String: Any]])
        let requests = try rows.map { row -> CreativeReferenceImport in
            let name = try #require(row["file_name"] as? String)
            return .init(source: URL(fileURLWithPath: try #require(row["path"] as? String)), role: name == "style_guide.md" ? .styleGuide : .tastePrinciples,
                expectedSHA256: try #require(row["sha256"] as? String), provenance: .init(libraryFileID: row["library_file_id"] as? String, backingFileID: row["file_id"] as? String, version: row["version"] as? Int, originalPath: try #require(row["path"] as? String)))
        }
        let repo = ProjectRepository()
        let result = try await repo.addCreativeReferences(requests, to: repo.open(folder))
        let context = try await repo.creativeReferenceContext(project: result)
        #expect(context.count == requests.count)
        print("CREATIVE_REFERENCE_INCLUSION=" + String(decoding: try JSONEncoder().encode(context.map(\.0)), as: UTF8.self))
    }
}
