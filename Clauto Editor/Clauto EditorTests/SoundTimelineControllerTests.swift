import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif
import SoundBrowserCore

@MainActor @Suite(.serialized) struct SoundTimelineControllerTests {
    private func fixture() async throws -> (URL,Project,CutVersion) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("clauto-sound-controller-"+UUID().uuidString)
        let engine=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project=try await ProjectRepository().create(name:"SYNTHETIC Sound Controller",root:root,engine:engine)
        let folder=project.folder.appendingPathComponent("cuts/v001/exports");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let xml=Data("""
        <?xml version="1.0"?><!DOCTYPE fcpxml><fcpxml version="1.13"><resources><format id="r1" frameDuration="1001/24000s" width="1920" height="1080"/><asset id="r2" name="Synthetic"><media-rep kind="original-media" src="file:///synthetic/fixture.wav"/></asset></resources><library><event><project><sequence format="r1" duration="48048/24000s"><spine><asset-clip ref="r2" offset="0s" start="0s" duration="48048/24000s"><asset-clip name="Idea #2" ref="r2" lane="-1" offset="10010/24000s" start="20020/24000s" duration="24024/24000s" audioRole="effects.foley" srcEnable="audio"><adjust-volume amount="-15dB"/></asset-clip></asset-clip></spine></sequence></project></event></library></fcpxml>
        """.utf8)
        try xml.write(to:folder.appendingPathComponent("timeline.fcpxml"))
        try JSONEncoder().encode(["saved_sha256":SoundBrowserCore.digest(xml)]).write(to:folder.appendingPathComponent("timeline.snapshot.json"))
        let version=CutVersion(number:1,label:"Synthetic only; no human approval",engineVersion:project.manifest.engineVersion,runID:UUID(),artifacts:["exports/timeline.fcpxml","exports/timeline.snapshot.json"],approvedPlanHash:String(repeating:"0",count:64))
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(version).write(to:folder.deletingLastPathComponent().appendingPathComponent("clauto-version.json"))
        try encoder.encode(version.id).write(to:project.folder.appendingPathComponent("cuts/current.json"))
        return (root,project,version)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"] != nil,"Requires the explicitly materialized representative package")) func actualControllerReplacesUndoesAndPublishesOnlyVerifiedSeparateTimeline() async throws {
        let library=try #require(ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"])
        let (root,project,version)=try await fixture();defer { try? FileManager.default.removeItem(at:root);unsetenv("CLAUTO_SOUND_QA_PREFERENCES");unsetenv("CLAUTO_SOUND_SILENT_QA") }
        setenv("CLAUTO_SOUND_QA_PREFERENCES",root.appendingPathComponent("browser.json").path,1);setenv("CLAUTO_SOUND_SILENT_QA","1",1)
        let controller=SoundTimelineController(project:project,version:version);await controller.load()
        #expect(controller.issue==nil);#expect(controller.cues.count==1)
        let browser=try #require(controller.browser),original=try #require(controller.document?.data)
        await browser.link(URL(fileURLWithPath:library))
        #expect(browser.availableCount==8)
        browser.select("BSB-2284");controller.replace(try browser.selectionReference())
        #expect(controller.document?.data==original);#expect(controller.issue != nil)
        browser.select("BSB-2278");controller.replace(try browser.selectionReference())
        #expect(controller.selectedCue?.name=="Boing Cartoon #2")
        #expect(controller.selectedCue?.sourceStartFrame==20 && controller.selectedCue?.durationFrames==24)
        #expect(controller.document?.canUndo==true)
        controller.undo();#expect(controller.document?.data==original)
        controller.redo();#expect(controller.selectedCue?.name=="Boing Cartoon #2")
        controller.save();let saved=try #require(controller.savedFolder)
        #expect(controller.issue==nil && !controller.unsaved)
        controller.save();#expect(controller.savedFolder==saved)
        let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:saved.appendingPathComponent("sound-timeline-edit.json"))) as? [String:Any]
        #expect(receipt?["admittedToEditorHistory"] as? Bool==false)
        #expect(receipt?["previewRendered"] as? Bool==false)
        #expect(try Data(contentsOf:project.folder.appendingPathComponent("cuts/v001/exports/timeline.fcpxml"))==original)
        #expect(try JSONDecoder().decode(UUID.self,from:Data(contentsOf:project.folder.appendingPathComponent("cuts/current.json")))==version.id)
        #expect(try SoundTimelineDocument(data:Data(contentsOf:saved.appendingPathComponent("timeline.fcpxml"))).cues.first?.name=="Boing Cartoon #2")
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"] != nil,"Requires the explicitly materialized representative package")) func staleCurrentPointerRefusesSaveAndRetainsDraft() async throws {
        let library=try #require(ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"])
        let (root,project,version)=try await fixture();defer { try? FileManager.default.removeItem(at:root);unsetenv("CLAUTO_SOUND_QA_PREFERENCES");unsetenv("CLAUTO_SOUND_SILENT_QA") }
        setenv("CLAUTO_SOUND_QA_PREFERENCES",root.appendingPathComponent("browser.json").path,1);setenv("CLAUTO_SOUND_SILENT_QA","1",1)
        let controller=SoundTimelineController(project:project,version:version);await controller.load()
        let browser=try #require(controller.browser);await browser.link(URL(fileURLWithPath:library));browser.select("BSB-2278");controller.replace(try browser.selectionReference())
        try JSONEncoder().encode(UUID()).write(to:project.folder.appendingPathComponent("cuts/current.json"))
        controller.save();#expect(controller.savedFolder==nil && controller.issue != nil && controller.unsaved)
        #expect(controller.selectedCue?.name=="Boing Cartoon #2")
        #expect(!FileManager.default.fileExists(atPath:project.folder.appendingPathComponent("build/derivatives").path))
    }
}
