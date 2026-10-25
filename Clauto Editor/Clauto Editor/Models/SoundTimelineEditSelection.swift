import Foundation
import SoundBrowserCore

struct SoundTimelineEditSelection: Codable,Equatable,Sendable {
    let schemaVersion: Int
    let projectID,parentVersionID,editID: UUID
    let parentTimelineSHA256,manifestSHA256,timelineSHA256: String
    func validate() throws {
        guard schemaVersion==1,[parentTimelineSHA256,manifestSHA256,timelineSHA256].allSatisfy(CutoutSourceInfo.validHash) else { throw WorkflowFailure.invalid("Choose a verified sound timeline edit.") }
    }
    func inspect(project:Project,version:CutVersion,source:SavedCutSource) throws -> (timeline:URL,manifest:URL) {
        try validate()
        guard projectID==project.id,parentVersionID==version.id,parentTimelineSHA256==source.timelineSHA256 else { throw WorkflowFailure.invalid("This sound edit belongs to a different saved cut.") }
        let root=try ProjectMutationLease.checkedRoot(project),folder=try root.child("build").child("derivatives").child(editID.uuidString)
        let bytes=try folder.read("sound-timeline-edit.json",limit:2*1024*1024)
        guard SoundBrowserCore.digest(bytes)==manifestSHA256,
              let receipt=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              receipt["kind"] as? String=="editable_sound_replacement",
              receipt["projectID"] as? String==projectID.uuidString,
              receipt["parentVersionID"] as? String==parentVersionID.uuidString,
              receipt["parentTimelineSHA256"] as? String==parentTimelineSHA256,
              receipt["timelineSHA256"] as? String==timelineSHA256,
              let object=receipt["references"] as? [String:Any] else { throw WorkflowFailure.invalid("The saved sound-edit receipt changed.") }
        let references=try JSONDecoder().decode([String:SoundSelectionReference].self,from:JSONSerialization.data(withJSONObject:object))
        guard references.count>0,references.count<=100 else { throw ProjectFailure.invalidProject }
        let catalog=try SoundCatalog.bundled(),xml=try folder.read("timeline.fcpxml",limit:8*1024*1024)
        guard SoundBrowserCore.digest(xml)==timelineSHA256 else { throw WorkflowFailure.invalid("The edited sound timeline changed.") }
        var urls: [String:URL] = [:],total=0
        for (cue,ref) in references {
            let asset=try ref.validate(catalog:catalog),leaf=ref.expectedSHA256+".wav"
            let data=try folder.read(leaf,limit:64*1024*1024);total += data.count
            guard total<=128*1024*1024,data.count==asset.bytes,SoundBrowserCore.digest(data)==ref.expectedSHA256 else { throw WorkflowFailure.invalid("A replacement audio snapshot changed or exceeds its budget.") }
            let decoded=try WaveEnvelope.decode(data)
            guard let item=try SoundTimelineDocument(data:xml).cues.first(where:{ $0.id==cue }),decoded.duration>=item.requiredSourceSeconds else { throw WorkflowFailure.invalid("Replacement audio does not cover the preserved source trim.") }
            urls[cue]=folder.url.appendingPathComponent(leaf)
        }
        let original=try Data(contentsOf:source.timeline)
        guard SoundBrowserCore.digest(original)==parentTimelineSHA256 else { throw WorkflowFailure.invalid("The saved parent changed.") }
        try SoundTimelineDocument(data:xml).verifyReplacement(of:original,references:references,mediaURLs:urls,catalog:catalog)
        try root.checkPath();try folder.checkPath()
        return (folder.url.appendingPathComponent("timeline.fcpxml"),folder.url.appendingPathComponent("sound-timeline-edit.json"))
    }
}
