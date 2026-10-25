import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif
import SoundBrowserCore

@MainActor @Suite(.serialized) struct SoundTimelineControllerTests {
    private func fixture(realMedia:Bool=false) async throws -> (URL,Project,CutVersion) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("clauto-sound-controller-"+UUID().uuidString)
        let engine=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engineVersion=try String(contentsOf:engine.appendingPathComponent("ENGINE_VERSION"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        let project=try await ProjectRepository().create(name:"SYNTHETIC Sound Controller",root:root,engine:engine,engineVersion:engineVersion)
        let folder=project.folder.appendingPathComponent("cuts/v001/exports");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var xml=Data("""
        <?xml version="1.0"?><!DOCTYPE fcpxml><fcpxml version="1.13"><resources><format id="r1" frameDuration="1001/24000s" width="1920" height="1080"/><asset id="r2" name="Synthetic"><media-rep kind="original-media" src="file:///synthetic/fixture.wav"/></asset></resources><library><event><project><sequence format="r1" duration="48048/24000s"><spine><asset-clip ref="r2" offset="0s" start="0s" duration="48048/24000s"><asset-clip name="Idea #2" ref="r2" lane="-1" offset="10010/24000s" start="20020/24000s" duration="24024/24000s" audioRole="effects.foley" srcEnable="audio"><adjust-volume amount="-15dB"/></asset-clip></asset-clip></spine></sequence></project></event></library></fcpxml>
        """.utf8)
        if realMedia {
            let video=project.folder.appendingPathComponent("synthetic-silent.mp4")
            let generated=try await ProcessRunner().run(ProcessCommand(executable:URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg"),arguments:["-nostdin","-v","error","-f","lavfi","-i","color=c=gray:s=320x180:r=24000/1001","-f","lavfi","-i","anullsrc=r=48000:cl=stereo","-t","3","-c:v","libx264","-c:a","aac","-n",video.path],directory:root,timeout:.seconds(30)),onLine:nil)
            #expect(generated.succeeded)
            let library=try #require(ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"])
            let old=URL(fileURLWithPath:library).appendingPathComponent("audio/bigsoundbank-reactions/BSB-1399-idea-2.wav")
            var text=String(decoding:xml,as:UTF8.self).replacingOccurrences(of:"file:///synthetic/fixture.wav",with:video.absoluteString)
            text=text.replacingOccurrences(of:"</resources>",with:"<asset id=\"r3\" name=\"Idea #2\"><media-rep kind=\"original-media\" src=\""+old.absoluteString+"\"/></asset></resources>")
            text=text.replacingOccurrences(of:"name=\"Idea #2\" ref=\"r2\"",with:"name=\"Idea #2\" ref=\"r3\"")
            xml=Data(text.utf8)
        }
        try xml.write(to:folder.appendingPathComponent("timeline.fcpxml"))
        try JSONEncoder().encode(["saved_sha256":SoundBrowserCore.digest(xml)]).write(to:folder.appendingPathComponent("timeline.snapshot.json"))
        let version=CutVersion(number:1,label:"Synthetic only; no human approval",engineVersion:project.manifest.engineVersion,runID:UUID(),artifacts:["exports/timeline.fcpxml","exports/timeline.snapshot.json"],approvedPlanHash:String(repeating:"0",count:64))
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(version).write(to:folder.deletingLastPathComponent().appendingPathComponent("clauto-version.json"))
        try encoder.encode(version.id).write(to:project.folder.appendingPathComponent("cuts/current.json"))
        return (root,project,version)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"] != nil,"Requires explicit representative package")) func replacementUsesNormalExportAndRenderedAudioMatchesChosenTrimAndGain() async throws {
        let library=try #require(ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"])
        let (root,project,version)=try await fixture(realMedia:true)
        defer { try? FileManager.default.removeItem(at:root);unsetenv("CLAUTO_SOUND_QA_PREFERENCES");unsetenv("CLAUTO_SOUND_SILENT_QA") }
        setenv("CLAUTO_SOUND_QA_PREFERENCES",root.appendingPathComponent("browser.json").path,1);setenv("CLAUTO_SOUND_SILENT_QA","1",1)
        let controller=SoundTimelineController(project:project,version:version);await controller.load()
        let browser=try #require(controller.browser);await browser.link(URL(fileURLWithPath:library));browser.select("BSB-2278");controller.replace(try browser.selectionReference());controller.save()
        #expect(controller.issue==nil)
        let selection=try #require(controller.exportSelection)
        let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine=root.appendingPathComponent("fixture-engine"),bin=engine.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
        for name in ["run","ENGINE_VERSION"] { try FileManager.default.copyItem(at:repository.appendingPathComponent(name),to:engine.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at:engine.appendingPathComponent("scripts"),withDestinationURL:repository.appendingPathComponent("scripts"))
        try FileManager.default.createSymbolicLink(at:bin.appendingPathComponent("python"),withDestinationURL:URL(fileURLWithPath:"/opt/homebrew/bin/python3.12"))
        let disk=WorkflowRepository(),request=DerivativeRequest(aspect:"16:9",resolution:.hd,soundTimelineEdit:selection)
        let exported=try await DerivativeService(runner:ProcessRunner(),disk:disk).export(request,version:version,project:project,engine:engine,onLine:{ _ in })
        #expect(exported.request==request)
        #expect(try await disk.derivatives(project:project).contains(where:{$0.id==exported.id}))
        let output=project.folder.appendingPathComponent("build/derivatives/"+exported.id.uuidString)
        let checked=try await ProcessRunner().run(ProcessCommand(executable:URL(fileURLWithPath:"/opt/homebrew/bin/python3.12"),arguments:[repository.appendingPathComponent("SoundBrowser/Integration/verify_rendered_replacement.py").path,output.appendingPathComponent("review.mp4").path,URL(fileURLWithPath:library).appendingPathComponent("audio/bigsoundbank-reactions/BSB-2278-boing-cartoon-2.wav").path,URL(fileURLWithPath:library).appendingPathComponent("audio/bigsoundbank-reactions/BSB-1399-idea-2.wav").path],directory:root,timeout:.seconds(30)),onLine:nil)
        #expect(checked.succeeded,Comment(rawValue:checked.output+checked.error))
        print("Silent rendered replacement evidence: "+checked.output)
        #expect(try DerivativeService.digest(project.folder.appendingPathComponent("cuts/v001/exports/timeline.fcpxml"))==selection.parentTimelineSHA256)
        #expect(try JSONDecoder().decode(UUID.self,from:Data(contentsOf:project.folder.appendingPathComponent("cuts/current.json")))==version.id)
        let saved=try #require(controller.savedFolder),xmlURL=saved.appendingPathComponent("timeline.fcpxml"),xml=try Data(contentsOf:xmlURL)
        try Data(String(decoding:xml,as:UTF8.self).replacingOccurrences(of:"-15dB",with:"-14dB").utf8).write(to:xmlURL)
        do { _=try selection.inspect(project:project,version:version,source:await disk.derivativeSource(version,project:project));Issue.record("Tampered replacement must fail") } catch {}
        let (fadeRoot,fadeProject,fadeVersion)=try await fixture(realMedia:true)
        defer { try? FileManager.default.removeItem(at:fadeRoot) }
        let parent=fadeProject.folder.appendingPathComponent("cuts/v001/exports/timeline.fcpxml")
        let fadeXML=Data(try String(contentsOf:parent,encoding:.utf8).replacingOccurrences(of:"<adjust-volume amount=\"-15dB\"/>",with:"<adjust-volume amount=\"-15dB\"><param name=\"amount\"><keyframeAnimation><keyframe time=\"20020/24000s\" value=\"-96\"/><keyframe time=\"22022/24000s\" value=\"-15\"/></keyframeAnimation></param></adjust-volume>").utf8)
        try fadeXML.write(to:parent)
        try JSONEncoder().encode(["saved_sha256":SoundBrowserCore.digest(fadeXML)]).write(to:parent.deletingLastPathComponent().appendingPathComponent("timeline.snapshot.json"))
        let fadeController=SoundTimelineController(project:fadeProject,version:fadeVersion);await fadeController.load()
        let fadeBrowser=try #require(fadeController.browser);await fadeBrowser.link(URL(fileURLWithPath:library));fadeBrowser.select("BSB-2278");fadeController.replace(try fadeBrowser.selectionReference());fadeController.save()
        let fadeSelection=try #require(fadeController.exportSelection)
        do {
            _=try await DerivativeService(runner:ProcessRunner(),disk:disk).export(DerivativeRequest(aspect:"16:9",resolution:.hd,soundTimelineEdit:fadeSelection),version:fadeVersion,project:fadeProject,engine:engine,onLine:{ _ in })
            Issue.record("Animated envelopes require explicit export refusal")
        } catch { #expect(error.localizedDescription.contains("Animated volume requires Final Cut review")) }
        #expect(try await disk.derivatives(project:fadeProject).isEmpty)
        #expect(try Data(contentsOf:parent)==fadeXML)
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
