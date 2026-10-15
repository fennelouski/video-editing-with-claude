import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor ScriptMutationProbeState {
    var finished = false
    func complete() { finished = true }
}

struct ProjectScriptSelectionTests {
    @Test func simultaneousFirstBriefAndScriptSaveCreateOneSharedLockAndKeepBothInputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-first-save-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 {
            let first = ProjectRepository(), second = ProjectRepository()
            let project = try await first.create(name: "First-save fixture",root: root.appendingPathComponent(String(index)),engine: root,engineVersion: "synthetic")
            #expect(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent(".clauto/project-mutation.lock").path))
            var draft = project.brief; draft.about = "New project's first typed words"
            let words = draft
            async let brief = first.saveBrief(words,project: project)
            async let script = second.approveScript("Exact first script",project: project)
            _ = try await (brief,script)
            let saved = try await first.open(project.folder)
            #expect(saved.brief == words && saved.manifest.mutationRevision == 3)
            #expect(try ProjectScriptSelectionStore.read(project: saved)?.bytes == Data("Exact first script".utf8))
        }
    }

    private struct Fixture {
        let root: URL
        let engine: URL
        let repository: ProjectRepository
        let project: Project
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-script-choice-"+UUID().uuidString)
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"),withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: engine.appendingPathComponent("ENGINE_VERSION"))
        let repo = ProjectRepository()
        var project = try await repo.create(name: "Synthetic script inputs",root: root.appendingPathComponent("projects"),engine: engine,engineVersion: "synthetic")
        let clip = root.appendingPathComponent("camera.MOV"); try Data("Synthetic clip placeholder; never decoded".utf8).write(to: clip)
        project = try await repo.add([clip],to: project)
        project = try await repo.approveScript("Original script. [[NOTE: synthetic]]",project: project)
        return .init(root: root,engine: engine,repository: repo,project: project)
    }
    private func document(_ f: Fixture,name: String,bytes: Data,project: Project? = nil) async throws -> (Project,ProjectFile) {
        let source = f.root.appendingPathComponent(name); try bytes.write(to: source)
        let updated = try await f.repository.add([source],to: project ?? f.project,group: .scripts)
        return (updated,try #require(updated.manifest.files.last))
    }
    private func wordDocument(_ f: Fixture,comment: String = "[[NOTE: preserve this exact comment]]") async throws -> Data {
        let url = f.root.appendingPathComponent("word-fixture.docx")
        let code = #"""
import sys,zipfile
from xml.sax.saxutils import escape
with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_DEFLATED) as z:
 z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
 z.writestr('word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:commentRangeStart w:id="1"/><w:r><w:t>Synthetic words</w:t></w:r><w:commentRangeEnd w:id="1"/></w:p></w:body></w:document>')
 z.writestr('word/comments.xml',f'<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:comment w:id="1"><w:p><w:r><w:t>{escape(sys.argv[2])}</w:t></w:r></w:p></w:comment></w:comments>')
"""#
        let result = try await ProcessRunner().run(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"),arguments: ["-c",code,url.path,comment]),onLine: nil)
        #expect(result.succeeded); return try Data(contentsOf: url)
    }
    @Test func explicitWordReplacementWinsOverOldMarkdownAndRetainsEveryPreparedInput() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let workflow = WorkflowRepository(), first = try await workflow.prepare(project: f.project,engine: f.engine,label: "Original")
        let original = try Data(contentsOf: first.folder.appendingPathComponent("inputs/script/script.md"))
        let word = try await wordDocument(f), (withWord,file) = try await document(f,name: "replacement.DOCX",bytes: word)
        let selected = try await f.repository.selectScript(file,project: withWord)
        let second = try await workflow.prepare(project: selected,engine: f.engine,label: "Word replacement")
        #expect(try await workflow.settings(second,project: selected,engine: f.engine)["approved_script"]?.hasSuffix("/inputs/script/script.docx") == true)
        #expect(try Data(contentsOf: second.folder.appendingPathComponent("inputs/script/script.docx")) == word)
        #expect(!FileManager.default.fileExists(atPath: second.folder.appendingPathComponent("inputs/script/script.md").path))
        let (withText,text) = try await document(f,name: "newest.txt",bytes: Data("Third version".utf8),project: selected)
        let next = try await f.repository.selectScript(text,project: withText)
        #expect(try Data(contentsOf: first.folder.appendingPathComponent("inputs/script/script.md")) == original)
        #expect(try Data(contentsOf: second.folder.appendingPathComponent("inputs/script/script.docx")) == word)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("replacement.DOCX")) == word)
        _ = try await workflow.settings(first,project: next,engine: f.engine)
        _ = try await workflow.settings(second,project: next,engine: f.engine)
        #expect(first.scriptInputSHA256 != second.scriptInputSHA256 && second.scriptSelectionReceiptSHA256 != nil)
    }
    @Test func changingAnIntakeCopyDoesNotRetargetItsSavedSelectionUntilExplicitlyReselected() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (project,file) = try await document(f,name: "editable.md",bytes: Data("Saved original".utf8))
        let selected = try await f.repository.selectScript(file,project: project)
        let before = try #require(try ProjectScriptSelectionStore.read(project: selected))
        try Data("New local edit".utf8).write(to: selected.folder.appendingPathComponent(file.relativePath))
        #expect(try ProjectScriptSelectionStore.read(project: selected)?.bytes == before.bytes)
        let next = try await f.repository.selectScript(file,project: selected), after = try #require(try ProjectScriptSelectionStore.read(project: next))
        #expect(after.bytes == Data("New local edit".utf8) && after.reference.id != before.reference.id)
        let history = selected.folder.appendingPathComponent(".clauto/script-selections/"+before.reference.id.uuidString+"/script.md")
        #expect(try Data(contentsOf: history) == before.bytes)
    }
    @Test func removingTheSelectedFileRequiresAReplacementInsteadOfFallingBackToAnOlderScript() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (project,file) = try await document(f,name: "chosen.txt",bytes: Data("Chosen replacement".utf8))
        let selected = try await f.repository.selectScript(file,project: project), before = try #require(try ProjectScriptSelectionStore.read(project: selected))
        try Data("Obsolete legacy draft".utf8).write(to: selected.folder.appendingPathComponent("script/script.md"))
        let removed = try await f.repository.remove(file,from: selected)
        #expect(removed.manifest.scriptSelection == nil && removed.manifest.requiresScriptSelection == true)
        #expect(FileManager.default.fileExists(atPath: removed.folder.appendingPathComponent("script/script.md").path))
        #expect(throws: (any Error).self) { _ = try ProjectScriptSelectionStore.read(project: removed) }
        await #expect(throws: (any Error).self) { _ = try await WorkflowRepository().prepare(project: removed,engine: f.engine,label: "Must choose") }
        #expect(try Data(contentsOf: removed.folder.appendingPathComponent(".clauto/script-selections/"+before.reference.id.uuidString+"/script.txt")) == before.bytes)
    }
    @Test(arguments: ["source","receipt","missing","symlink","cleared_manifest"])
    func changedSavedSelectionCannotUseTheLegacyFallback(_ fault: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selected = try #require(f.project.manifest.scriptSelection)
        let folder = f.project.folder.appendingPathComponent(".clauto/script-selections/"+selected.id.uuidString)
        switch fault {
        case "source": try Data("Changed".utf8).write(to: folder.appendingPathComponent("script.md"))
        case "receipt": try Data("{}".utf8).write(to: folder.appendingPathComponent("selection.json"))
        case "missing": try FileManager.default.removeItem(at: folder)
        case "cleared_manifest":
            let url = f.project.folder.appendingPathComponent("clauto-project.json")
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
            manifest.removeValue(forKey: "scriptSelection"); manifest.removeValue(forKey: "requiresScriptSelection")
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        default:
            try FileManager.default.moveItem(at: folder,to: f.root.appendingPathComponent("moved-selection"))
            try FileManager.default.createSymbolicLink(at: folder,withDestinationURL: f.root.appendingPathComponent("moved-selection"))
        }
        #expect(throws: (any Error).self) { _ = try ProjectScriptSelectionStore.read(project: f.project) }
        await #expect(throws: (any Error).self) { _ = try await WorkflowRepository().prepare(project: f.project,engine: f.engine,label: "Refuse fallback") }
    }
    @Test func changedRunScriptRefusesResumeAndPublicationEvenWhenPathsAreRehashed() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let workflow = WorkflowRepository(); var run = try await workflow.prepare(project: f.project,engine: f.engine,label: "Bound input")
        let input = run.folder.appendingPathComponent("inputs/script/script.md"), pointer = f.project.folder.appendingPathComponent("cuts/current.json"), sentinel = Data("Original current".utf8)
        try sentinel.write(to: pointer); try Data("Changed after preparation".utf8).write(to: input)
        await #expect(throws: (any Error).self) { _ = try await workflow.settings(run,project: f.project,engine: f.engine) }
        let pathsURL = run.folder.appendingPathComponent("paths.json")
        var paths = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: pathsURL)) as? [String:String])
        paths["script_input_sha256"] = TranscriptSourceMap.sha(try Data(contentsOf: input))
        try JSONSerialization.data(withJSONObject: paths).write(to: pathsURL)
        await #expect(throws: (any Error).self) { _ = try await workflow.settings(run,project: f.project,engine: f.engine) }
        run.state = .complete
        await #expect(throws: (any Error).self) { _ = try await workflow.snapshot(run,project: f.project) }
        #expect(try Data(contentsOf: pointer) == sentinel)
    }
    @Test func sourceAliasesCannotReplaceTheSelectedScriptAndOriginalBytesStayUntouched() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (project,file) = try await document(f,name: "source.txt",bytes: Data("Original user source".utf8))
        let copy = project.folder.appendingPathComponent(file.relativePath)
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.createSymbolicLink(at: copy,withDestinationURL: f.root.appendingPathComponent("source.txt"))
        await #expect(throws: (any Error).self) { _ = try await f.repository.selectScript(file,project: project) }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("source.txt")) == Data("Original user source".utf8))
        #expect(try ProjectScriptSelectionStore.read(project: project)?.reference == f.project.manifest.scriptSelection)
    }
    @Test func savingBriefScriptNeverOverwritesUserDocumentsAndFailedChoicesKeepThePreviousSelection() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = Data("User edited draft that must remain".utf8), draft = f.project.folder.appendingPathComponent("script/script.md")
        try original.write(to: draft)
        let selected = try await f.repository.approveScript("New text chosen in Brief",project: f.project)
        #expect(try Data(contentsOf: draft) == original)
        let reference = selected.manifest.scriptSelection
        for (name,bytes) in [("empty.md",Data()),("invalid.md",Data([0xff])),("invalid.docx",Data("Not a Word archive".utf8))] {
            let (updated,file) = try await document(f,name: name,bytes: bytes,project: selected)
            await #expect(throws: (any Error).self) { _ = try await f.repository.selectScript(file,project: updated) }
            #expect(try await f.repository.open(selected.folder).manifest.scriptSelection == reference)
        }
        #expect(try ProjectScriptSelectionStore.read(project: selected)?.bytes == Data("New text chosen in Brief".utf8))
    }
    @Test func queuedBriefAutosaveAndScriptChoiceKeepBothUpdates() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (project,file) = try await document(f,name: "selected.txt",bytes: Data("Selected script words".utf8))
        var brief = project.brief; brief.about = "User description entered during script selection"
        async let save = f.repository.saveBrief(brief,project: project)
        async let selection = f.repository.selectScript(file,project: project)
        _ = try await (save,selection)
        let reopened = try await f.repository.open(project.folder)
        #expect(reopened.brief.about == brief.about && reopened.manifest.scriptSelection?.sourceFileID == file.id)
        #expect(try ProjectScriptSelectionStore.read(project: reopened)?.bytes == Data("Selected script words".utf8))
    }
    @Test func replacementReadsAnUpdatedWordAtTheSameOriginalPathAndKeepsPreviousCopies() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try await wordDocument(f), (project,file) = try await document(f,name: "working.docx",bytes: old)
        let selected = try await f.repository.selectScript(file,project: project), workflow = WorkflowRepository()
        let first = try await workflow.prepare(project: selected,engine: f.engine,label: "Before replacement")
        let updated = try await wordDocument(f,comment: "[[NOTE: new user annotation & source]]"), source = f.root.appendingPathComponent("working.docx")
        try updated.write(to: source)
        let next = try await f.repository.replaceScript(file,with: source,project: selected)
        let current = try #require(next.manifest.files.first { $0.id == file.id }), snapshot = try #require(try ProjectScriptSelectionStore.read(project: next))
        #expect(old != updated && current.relativePath != file.relativePath && current.id == file.id)
        #expect(snapshot.receipt.replacedFile == file && snapshot.bytes == updated)
        #expect(try Data(contentsOf: selected.folder.appendingPathComponent(file.relativePath)) == old)
        #expect(try Data(contentsOf: first.folder.appendingPathComponent("inputs/script/script.docx")) == old)
        #expect(try Data(contentsOf: source) == updated)
        let second = try await workflow.prepare(project: next,engine: f.engine,label: "After replacement")
        #expect(try Data(contentsOf: second.folder.appendingPathComponent("inputs/script/script.docx")) == updated)
        await #expect(throws: (any Error).self) { _ = try await f.repository.selectScript(file,project: next) } // stale row cannot choose a different source silently
        let invalid = f.root.appendingPathComponent("invalid-replacement.docx"); try Data("Not a Word document".utf8).write(to: invalid)
        await #expect(throws: (any Error).self) { _ = try await f.repository.replaceScript(current,with: invalid,project: next) }
        #expect(try await f.repository.open(next.folder).manifest.scriptSelection == next.manifest.scriptSelection)
    }
    @Test func separateRepositoryInstancesKeepSuccessfulScriptAndBriefUpdates() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let other = ProjectRepository()
        for index in 0..<3 {
            var brief = f.project.brief
            brief.about = String(repeating: "Synthetic brief update ",count: 500_000)
            let submitted = brief, save = Task { try await f.repository.saveBrief(submitted,project: f.project) }
            try await Task.sleep(for: .milliseconds(5))
            let selected = try await other.approveScript("Intended script \(index)",project: f.project)
            _ = try await save.value
            let reopened = try await other.open(f.project.folder)
            #expect(reopened.brief.about == submitted.about)
            #expect(reopened.manifest.scriptSelection == selected.manifest.scriptSelection)
            #expect(try ProjectScriptSelectionStore.read(project: reopened)?.bytes == Data("Intended script \(index)".utf8))
        }
    }
    @Test func lateScriptAndBriefResponsesPreserveTheNewestLocalDraftAndManifest() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var state = ProjectPresentationState(), typed = f.project.brief
        typed.about = "New user words awaiting autosave"
        let oldToken = state.submit(typed,for: f.project)
        let selected = try await f.repository.approveScript("Chosen exact input",project: f.project)
        let shown = state.present(selected,over: f.project)
        #expect(shown.brief == typed && shown.manifest.scriptSelection == selected.manifest.scriptSelection)
        var latest = typed; latest.about = "An even newer edit while writes finish"
        let newToken = state.submit(latest,for: f.project)
        let savedOld = try await f.repository.saveBrief(typed,project: f.project)
        let oldAcknowledged = state.acknowledge(oldToken,for: f.project)
        #expect(!oldAcknowledged)
        #expect(state.present(savedOld,over: shown).brief == latest && state.hasUnsavedBriefs)
        let savedNew = try await f.repository.saveBrief(latest,project: f.project)
        let newestAcknowledged = state.acknowledge(newToken,for: f.project)
        #expect(newestAcknowledged && !state.hasUnsavedBriefs)
        let newest = state.present(savedNew,over: shown), late = state.present(selected,over: newest)
        #expect(late.brief == latest && late.manifest.mutationRevision == savedNew.manifest.mutationRevision)
        #expect(late.manifest.scriptSelection == selected.manifest.scriptSelection)
        #expect(try await f.repository.open(f.project.folder).manifest.mutationRevision == savedNew.manifest.mutationRevision)
        #expect((savedNew.manifest.mutationRevision ?? 0) > (selected.manifest.mutationRevision ?? 0))
    }
    @Test func failedBriefAcknowledgementKeepsDraftOwnershipUntilItsOwnSuccessfulRetry() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var state = ProjectPresentationState(), brief = f.project.brief
        brief.about = "Unsaved words must stay visible"
        let first = state.submit(brief,for: f.project)
        #expect(state.hasUnsavedBriefs && state.present(f.project,over: nil).brief == brief)
        let retry = state.submit(brief,for: f.project)
        let staleAcknowledged = state.acknowledge(first,for: f.project)
        #expect(!staleAcknowledged && state.hasUnsavedBriefs)
        let saved = try await f.repository.saveBrief(brief,project: f.project)
        let retryAcknowledged = state.acknowledge(retry,for: f.project)
        #expect(retryAcknowledged)
        #expect(state.present(saved,over: f.project).brief == brief && !state.hasUnsavedBriefs)
    }
    @Test func copiedProjectIDsNeverRedirectAnExplicitOpenOrBorrowAnotherFoldersDraft() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var backup = f.project, current = f.project, state = ProjectPresentationState(), words = f.project.brief
        backup.folder = f.root.appendingPathComponent("Older backup"); backup.manifest.mutationRevision = 1
        current.manifest.mutationRevision = 40; words.about = "Original folder's unsaved draft"
        let token = state.submit(words,for: current)
        #expect(throws: (any Error).self) { try ProjectPresentationState.requireUnambiguousOpen(backup,among: [current]) }
        #expect(state.present(backup,over: current).folder == backup.folder)
        #expect(state.present(backup,over: current).brief == backup.brief && state.pendingBrief(for: backup) == nil)
        let wrongRootAcknowledged = state.acknowledge(token,for: backup)
        #expect(!wrongRootAcknowledged && state.hasUnsavedBriefs)
        #expect(state.present(current,over: current).brief == words)
        var alias = current; alias.folder = current.folder.appendingPathComponent(".").standardizedFileURL
        try ProjectPresentationState.requireUnambiguousOpen(alias,among: [current])
        #expect(ProjectPresentationState.sameRoot(current,alias))
    }
    @Test func samePathPhysicalReplacementCannotBorrowStateOrAcceptAStaleMutation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let backup = f.root.appendingPathComponent("Backup"), displaced = f.root.appendingPathComponent("Displaced original")
        try FileManager.default.copyItem(at: f.project.folder,to: backup)
        let advanced = try await f.repository.approveScript("New original selection",project: f.project)
        try FileManager.default.moveItem(at: advanced.folder,to: displaced)
        try FileManager.default.copyItem(at: backup,to: advanced.folder)
        let restored = try await f.repository.open(advanced.folder), before = try Data(contentsOf: restored.folder.appendingPathComponent("clauto-project.json"))
        #expect(restored.id == advanced.id && restored.folder.path == advanced.folder.path && restored.folderIdentity != advanced.folderIdentity)
        #expect(throws: (any Error).self) { try ProjectPresentationState.requireUnambiguousOpen(restored,among: [advanced]) }
        var state = ProjectPresentationState(), brief = advanced.brief; brief.about = "Words belonging to displaced original"
        #expect(throws: (any Error).self) { try state.requireCutInput(restored,chosen: advanced) }
        let token = state.submit(brief,for: advanced)
        #expect(state.pendingBrief(for: restored) == nil && state.present(restored,over: advanced).manifest.scriptSelection == restored.manifest.scriptSelection)
        let acknowledged = state.acknowledge(token,for: restored)
        #expect(!acknowledged && state.hasUnsavedBriefs)
        await #expect(throws: (any Error).self) { _ = try await f.repository.approveScript("Must not change backup",project: advanced) }
        await #expect(throws: (any Error).self) { _ = try await f.repository.saveBrief(brief,project: advanced) }
        await #expect(throws: (any Error).self) { _ = try await WorkflowRepository().prepare(project: advanced,engine: f.engine,label: "Must not run in replacement") }
        #expect(throws: (any Error).self) { _ = try ProjectScriptSelectionStore.read(project: advanced) }
        #expect(try Data(contentsOf: restored.folder.appendingPathComponent("clauto-project.json")) == before)
        #expect(try ProjectScriptSelectionStore.read(project: restored)?.reference == f.project.manifest.scriptSelection)
    }
    @Test func cutInputAdmissionRequiresTheChosenRootAndAcknowledgedBrief() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var state = ProjectPresentationState(), brief = f.project.brief; brief.about = "Latest words must reach this run"
        let token = state.submit(brief,for: f.project), reopened = try await f.repository.open(f.project.folder)
        #expect(throws: (any Error).self) { try state.requireCutInput(reopened,chosen: f.project) }
        let saved = try await f.repository.saveBrief(brief,project: f.project)
        let acknowledged = state.acknowledge(token,for: f.project)
        #expect(acknowledged && saved.brief == brief)
        try state.requireCutInput(saved,chosen: f.project)
        var unrelated = saved; unrelated.manifest.id = UUID()
        #expect(throws: (any Error).self) { try state.requireCutInput(unrelated,chosen: f.project) }
    }
    @Test func realSymlinkAliasWithNoDirectoryURLHintSharesTheSamePhysicalRootAndDraft() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let link = f.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: f.project.folder)
        let alias = try await f.repository.open(URL(fileURLWithPath: link.path,isDirectory: false))
        #expect(alias.folder.path == f.project.folder.path)
        try ProjectPresentationState.requireUnambiguousOpen(alias,among: [f.project])
        #expect(ProjectPresentationState.sameRoot(alias,f.project) && alias.folderIdentity == f.project.folderIdentity)
        var state = ProjectPresentationState(), brief = f.project.brief; brief.about = "Same physical folder's draft"
        let token = state.submit(brief,for: f.project)
        #expect(state.pendingBrief(for: alias) == brief && state.present(alias,over: f.project).brief == brief)
        let acknowledged = state.acknowledge(token,for: alias)
        #expect(acknowledged && !state.hasUnsavedBriefs)
        let chosen = try await f.repository.approveScript("Input chosen through alias",project: alias)
        #expect(try ProjectScriptSelectionStore.read(project: chosen)?.bytes == Data("Input chosen through alias".utf8))
    }
    @Test func retargetingAnAliasWhileAWriterWaitsCannotMixTwoProjectIdentities() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let other = ProjectRepository(), second = try await other.create(name: "Another synthetic project",root: f.root.appendingPathComponent("projects"),engine: f.engine,engineVersion: "synthetic")
        let secondManifest = try Data(contentsOf: second.folder.appendingPathComponent("clauto-project.json")), link = f.root.appendingPathComponent("Retargetable alias")
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: f.project.folder)
        let handle = try await f.repository.open(URL(fileURLWithPath: link.path,isDirectory: false))
        #expect(handle.folder.path == f.project.folder.path)
        var owner: ProjectMutationLease? = try ProjectMutationLease.acquire(handle)
        var brief = handle.brief; brief.about = "Words for the original project only"
        let words = brief, flag = ScriptMutationProbeState()
        let waiter = Task { let saved = try await other.saveBrief(words,project: handle); await flag.complete(); return saved }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await flag.finished == false)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: second.folder)
        withExtendedLifetime(owner) {}; owner = nil
        let saved = try await waiter.value, first = try await f.repository.open(f.project.folder)
        #expect(saved.id == f.project.id && first.id == f.project.id && first.brief == words)
        #expect(try Data(contentsOf: second.folder.appendingPathComponent("clauto-project.json")) == secondManifest)
        #expect(try await other.open(link).id == second.id)
    }
}
