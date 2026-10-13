import Foundation
import Testing
import PDFKit
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct HandoffExportTests {
    private func reportFixture(_ root: URL, script: String) async throws -> (Project, CutVersion) {
        let project = try await ProjectRepository().create(name: "Synthetic report", root: root, engine: root)
        let versionRoot = project.folder.appendingPathComponent("cuts/v001")
        for section in ["inputs/script", "plan", "roughcut", "exports"] {
            try FileManager.default.createDirectory(at: versionRoot.appendingPathComponent(section), withIntermediateDirectories: true)
        }
        let values = ["inputs/script/000-old.txt": "OBSOLETE DRAFT", "inputs/script/approved.md": "The exact approved script.",
                      "inputs/script/selected.docx": "A synthetic Word package placeholder, never converted.",
                      "plan/video.plan.json": "{\"script\":\"\(script)\"}", "roughcut/video.heard.txt": "The verified audio says this."]
        for (file, text) in values { try text.write(to: versionRoot.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        let edl: [String: Any] = ["source": "synthetic.mov", "fps": 24000.0/1001,
            "keeps": [["start": 2.5, "end": 3.6], ["start": 5.1, "end": 6.4]], "drops": []]
        try JSONSerialization.data(withJSONObject: edl).write(to: versionRoot.appendingPathComponent("roughcut/video.edl.json"))
        let xml = """
        <fcpxml><library><event><project><sequence><spine>
        <asset-clip offset="0s" start="60060/24000s" duration="26026/24000s"/>
        <asset-clip offset="26026/24000s" start="122122/24000s" duration="31031/24000s"/>
        </spine></sequence></project></event></library></fcpxml>
        """
        try xml.write(to: versionRoot.appendingPathComponent("exports/video.fcpxml"), atomically: true, encoding: .utf8)
        let artifacts = ["inputs/script/000-old.txt", "inputs/script/approved.md", "inputs/script/selected.docx", "plan/video.plan.json", "roughcut/video.heard.txt", "roughcut/video.edl.json", "exports/video.fcpxml"]
        let version = CutVersion(number: 1, label: "Synthetic", engineVersion: "test", runID: UUID(), artifacts: artifacts, approvedPlanHash: "fixture")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(version).write(to: versionRoot.appendingPathComponent("clauto-version.json"))
        return (project, version)
    }

    @Test func onlyTheSelectedScriptIsExportedAndTimingsMatchTheSavedXML() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-report-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, version) = try await reportFixture(root, script: "approved.md")
        let disk = WorkflowRepository()
        let report = try await disk.handoffReport(version, project: project)
        #expect(report.sections.first?.text == "The exact approved script.")
        let shotList = try #require(report.sections.first { $0.title == "Shot list" })
        #expect(shotList.text.contains("Timeline 1.084s"))
        #expect(shotList.text.contains("Duration 1.293s"))
        let edl = project.folder.appendingPathComponent("cuts/v001/roughcut/video.edl.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: edl)) as? [String: Any])
        object["keeps"] = [["start": 5.1, "end": 6.4], ["start": 2.5, "end": 3.6]]
        try JSONSerialization.data(withJSONObject: object).write(to: edl)
        await #expect(throws: WorkflowFailure.self) { try await disk.handoffReport(version, project: project) }
    }

    @Test func selectedWordDocumentIsNotReplacedByOtherMarkdownNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-docx-report-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, version) = try await reportFixture(root, script: "selected.docx")
        let report = try await WorkflowRepository().handoffReport(version, project: project)
        #expect(report.sections.first?.text.contains("Word document") == true)
        #expect(report.sections.first?.text.contains("exact approved script") == false)
        #expect(report.sections.first?.text.contains("OBSOLETE") == false)
    }

    @Test func multipageReportPreservesAllTextAndPageNumbers() async throws {
        let lines = (1...90).map { "Shot \($0) | Timeline \($0)s\nA clear reason with café, flour & water. End of shot \($0)." }.joined(separator: "\n\n")
        let report = HandoffReport(title: "Synthetic handoff - v001", subtitle: "Test inputs only", sections: [.init(title: "Shot list", text: lines)])
        let bytes = try HandoffExportService.render(report)
        let pdf = try #require(PDFDocument(data: bytes))
        #expect(pdf.pageCount > 2)
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        #expect(text.contains("End of shot 90."))
        #expect(text.contains("café"))
        #expect(text.contains("Page \(pdf.pageCount)"))
        for number in 1...90 { #expect(text.contains("End of shot \(number).")) }
    }

    @Test func exportIsUniqueAndRefusesEscapedOutputFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await ProjectRepository().create(name: "Synthetic export", root: root, engine: root)
        let version = CutVersion(number: 1, label: "Fixture", engineVersion: "test", runID: UUID(), artifacts: [], approvedPlanHash: "test")
        let report = HandoffReport(title: "Synthetic", subtitle: "Test", sections: [.init(title: "Script", text: "A fixture.")])
        let exporter = HandoffExportService()
        let first = try await exporter.export(report, project: project, version: version)
        let bytes = try Data(contentsOf: first)
        let second = try await exporter.export(report, project: project, version: version)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == bytes)
        try FileManager.default.removeItem(at: project.folder.appendingPathComponent("exports"))
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.folder.appendingPathComponent("exports"), withDestinationURL: outside)
        await #expect(throws: ProjectFailure.self) { try await exporter.export(report, project: project, version: version) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_HANDOFF_ACCEPTANCE_ROOT"] != nil,
                   "Requires the completed synthetic cached-model version"))
    func exportCompletedSyntheticVersionForVisualReview() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAUTO_HANDOFF_ACCEPTANCE_ROOT"]))
        let evidence = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("acceptance-result.json"))) as? [String: Any])
        #expect(evidence["synthetic_only"] as? Bool == true)
        guard evidence["synthetic_only"] as? Bool == true else { return }
        let path = try #require(evidence["project"] as? String)
        let project = try await ProjectRepository().open(URL(fileURLWithPath: path))
        let disk = WorkflowRepository(), version = try #require(try await disk.current(project: project))
        let report = try await disk.handoffReport(version, project: project)
        #expect(report.sections.contains { $0.title == "Shot list" && $0.text.contains("Shot 1") })
        let url = try await HandoffExportService().export(report, project: project, version: version)
        #expect(PDFDocument(url: url)?.pageCount ?? 0 > 0)
        try url.path.write(to: root.appendingPathComponent("handoff-pdf-path.txt"), atomically: true, encoding: .utf8)
    }
}
