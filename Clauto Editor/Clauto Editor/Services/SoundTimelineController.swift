import Foundation
import Observation
import AppKit
import SoundBrowserCore

@Observable @MainActor final class SoundTimelineController {
    let project: Project
    let version: CutVersion
    var browser: SoundBrowserStore?
    var selectedCueID: String?
    var similarOnly = false { didSet { updateRecommendations() } }
    private(set) var document: SoundTimelineDocument?
    private(set) var issue: String?
    private(set) var savedFolder: URL?
    private(set) var revision = 0
    private var original: Data?
    private var versionBytes: Data?
    private var currentBytes: Data?
    private var timelineLeaf: String?
    private var snapshots: [String:Data] = [:]
    private var rootIdentity: RenderDirectoryIdentity?
    private var savedDocumentSHA256: String?
    private var lastSavedSelection: SoundTimelineEditSelection?
    init(project:Project,version:CutVersion) {
        self.project=project;self.version=version
        do {
            let catalog=try SoundCatalog.bundled()
            let prefs: URL
            if let path=ProcessInfo.processInfo.environment["CLAUTO_SOUND_QA_PREFERENCES"] { prefs=URL(fileURLWithPath:path) }
            else { prefs=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Clauto Editor/Sound Browser/browser.json") }
            #if DEBUG
            let silent: (any SoundPlaying)? = ProcessInfo.processInfo.environment["CLAUTO_SOUND_SILENT_QA"]=="1" ? SilentEditorSoundPlayer():nil
            #else
            let silent: (any SoundPlaying)? = nil
            #endif
            browser=SoundBrowserStore(catalog:catalog,preferencesURL:prefs,player:silent)
        } catch { issue=error.localizedDescription }
    }
    var cues: [SoundTimelineCue] { _=revision;return document?.cues ?? [] }
    var selectedCue: SoundTimelineCue? { cues.first { $0.id==selectedCueID } }
    var dirty: Bool { document?.data != original }
    var unsaved: Bool { dirty && document.map { SoundBrowserCore.digest($0.data) != savedDocumentSHA256 } == true }
    var exportSelection: SoundTimelineEditSelection? { dirty && !unsaved ? lastSavedSelection:nil }
    func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLAUTO_SOUND_SILENT_QA"]=="1" { SoundTimelineQAState.active=self }
        #endif
        do {
            _ = try await WorkflowRepository().derivativeSource(version,project:project)
            let root=try ProjectMutationLease.checkedRoot(project)
            guard let path=version.artifacts.first(where:{ $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }) else { throw ProjectFailure.invalidProject }
            let leaf=String(path.dropFirst("exports/".count));guard CreativeAssetFiles.validLeaf(leaf) else { throw ProjectFailure.invalidProject }
            let folder=try root.child("cuts").child(version.folderName)
            let bytes=try folder.child("exports").read(leaf,limit:8*1024*1024)
            document=try SoundTimelineDocument(data:bytes);original=bytes;timelineLeaf=leaf;rootIdentity=root.identity
            versionBytes=try folder.read("clauto-version.json",limit:1024*1024)
            currentBytes=try root.child("cuts").read("current.json",limit:1024)
            selectedCueID=cues.first?.id;revision += 1
            if let browser,!browser.mounts.isEmpty { await browser.recheck() }
        } catch { issue=error.localizedDescription }
    }
    func selectCue(_ id:String) { browser?.stop();selectedCueID=id;updateRecommendations() }
    func replace(_ reference:SoundSelectionReference) {
        do {
            guard let document,let browser,let id=selectedCueID else { throw WorkflowFailure.invalid("Choose a connected sound in this saved timeline.") }
            let snapshot=try browser.verifiedSelectionSnapshot(reference)
            guard let cue=selectedCue,try WaveEnvelope.decode(snapshot.data).duration>=cue.requiredSourceSeconds else { throw WorkflowFailure.invalid("This sound does not contain enough decoded samples for the existing trim. The cue was not changed.") }
            let retained=snapshots.reduce(0) { $0+$1.value.count }
            guard snapshots[reference.expectedSHA256] != nil || retained+snapshot.data.count<=128*1024*1024 else { throw WorkflowFailure.invalid("Save or discard this sound draft before retaining more replacement audio.") }
            try document.replace(cueID:id,reference:reference,sourceURL:snapshot.url,catalog:browser.catalog)
            snapshots[reference.expectedSHA256]=snapshot.data;revision += 1;savedFolder=nil;issue=nil;updateRecommendations()
        } catch { issue=error.localizedDescription }
    }
    func undo() { document?.undo();browser?.stop();revision += 1;savedFolder=nil;updateRecommendations() }
    func redo() { document?.redo();browser?.stop();revision += 1;savedFolder=nil;updateRecommendations() }
    func discard() { if let original { document=try? SoundTimelineDocument(data:original) };snapshots=[:];revision += 1;issue=nil }
    func save() {
        do {
            guard let document,let browser,let original,let versionBytes,let currentBytes,let timelineLeaf,unsaved else { return }
            let lease=try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
            guard lease.root.identity==rootIdentity else { throw ProjectFailure.invalidProject }
            let parent=try lease.root.child("cuts").child(version.folderName)
            guard try parent.child("exports").read(timelineLeaf,limit:8*1024*1024)==original,
                  try parent.read("clauto-version.json",limit:1024*1024)==versionBytes,
                  try lease.root.child("cuts").read("current.json",limit:1024)==currentBytes else { throw WorkflowFailure.invalid("The saved cut or current version changed. Reopen it before saving this replacement.") }
            let id=UUID(),output=try lease.root.child("build",create:true).child("derivatives",create:true).child(id.uuidString,create:true)
            var mapping: [String:URL] = [:],written=Set<String>()
            for (cue,ref) in document.references {
                _ = try ref.validate(catalog:browser.catalog)
                guard let data=snapshots[ref.expectedSHA256],SoundBrowserCore.digest(data)==ref.expectedSHA256 else { throw WorkflowFailure.invalid("Replacement sound snapshot is unavailable or changed.") }
                let leaf=ref.expectedSHA256+".wav"
                if written.insert(leaf).inserted { try output.writeNew(data,name:leaf) }
                mapping[cue]=output.url.appendingPathComponent(leaf)
            }
            let xml=try document.rewrittenMediaURLs(mapping);_ = try SoundTimelineDocument(data:xml)
            try output.writeNew(xml,name:"timeline.fcpxml")
            let refs=try JSONSerialization.jsonObject(with:JSONEncoder().encode(document.references))
            let receipt: [String:Any] = ["schemaVersion":1,"kind":"editable_sound_replacement","projectID":project.id.uuidString,"parentVersionID":version.id.uuidString,"parentTimelineSHA256":SoundBrowserCore.digest(original),"timelineSHA256":SoundBrowserCore.digest(xml),"references":refs,"previewRendered":false,"admittedToEditorHistory":false,"humanAudition":"NOT_AUDITIONED"]
            let receiptBytes=try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys])
            try output.writeNew(receiptBytes,name:"sound-timeline-edit.json")
            try lease.root.checkPath();try output.checkPath();savedFolder=output.url;savedDocumentSHA256=SoundBrowserCore.digest(document.data);issue=nil
            lastSavedSelection = .init(schemaVersion:1,projectID:project.id,parentVersionID:version.id,editID:id,parentTimelineSHA256:SoundBrowserCore.digest(original),manifestSHA256:SoundBrowserCore.digest(receiptBytes),timelineSHA256:SoundBrowserCore.digest(xml))
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLAUTO_SOUND_SILENT_QA"]=="1" {
                SoundTimelineQAState.active=self
                DispatchQueue.main.async { SoundTimelineQAState.capture() }
            }
            #endif
        } catch { issue=error.localizedDescription }
    }
    private func updateRecommendations() {
        guard let browser,let document,let selectedCueID else { return }
        browser.recommendedIDs=similarOnly ? Set(document.similarCandidates(cueID:selectedCueID,catalog:browser.catalog).prefix(100).map(\.id)):nil
    }
}
#if DEBUG
@MainActor private final class SilentEditorSoundPlayer: SoundPlaying {
    func start(data:Data,volume:Float,finished:@escaping @MainActor () -> Void) throws { SoundTimelineQAState.playbackStartAttempts += 1;throw WorkflowFailure.invalid("Audio output is blocked in isolated UI QA.") }
    func stop() {}
    func setVolume(_ volume:Float) {}
}
@MainActor enum SoundTimelineQAState {
    static weak var active: SoundTimelineController?
    static var playbackStartAttempts=0
    static func capture() {
        guard let path=ProcessInfo.processInfo.environment["CLAUTO_SOUND_QA_OUTPUT"],var window=NSApp.keyWindow else { return }
        while let sheet=window.attachedSheet { window=sheet }
        guard let view=window.contentView else { return }
        do {
            let controller=active
            let folder=URL(fileURLWithPath:path,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.layoutSubtreeIfNeeded();view.cacheDisplay(in:view.bounds,to:bitmap)
                if let png=bitmap.representation(using:.png,properties:[:]) { try png.write(to:folder.appendingPathComponent(controller == nil ? "clauto-editor-window-controls.png":"clauto-integrated-sound-editor.png")) }
            }
            let report: [String:Any] = ["catalogCount":controller?.browser?.catalog.assets.count ?? 0,"catalogVersion":controller?.browser?.catalog.version ?? "","availableCount":controller?.browser?.availableCount ?? 0,"playbackStartAttempts":playbackStartAttempts,"cues":(controller?.cues ?? []).map { ["id":$0.id,"name":$0.name,"timelineFrame":String($0.timelineStartFrame),"sourceFrame":String($0.sourceStartFrame),"durationFrames":String($0.durationFrames)] },"canUndo":controller?.document?.canUndo ?? false,"canRedo":controller?.document?.canRedo ?? false,"unsaved":controller?.unsaved ?? false,"savedFolder":controller?.savedFolder?.path ?? "","humanAudition":"NOT_AUDITIONED","windowWidth":window.frame.width,"windowHeight":window.frame.height,"windowZoomed":window.isZoomed]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("integrated-ui-report.json"))
        } catch { }
    }
}
#endif
