import SwiftUI
import SoundBrowserCore
import SoundBrowserUI

struct SoundTimelineEditorView: View {
    @State private var controller: SoundTimelineController
    @Environment(\.dismiss) private var dismiss
    init(project:Project,version:CutVersion) { _controller=State(initialValue:SoundTimelineController(project:project,version:version)) }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text("Sounds in v\(controller.version.number)").font(.title2.weight(.semibold))
                Spacer()
                Button("Undo replacement") { controller.undo() }.disabled(controller.document?.canUndo != true)
                Button("Redo") { controller.redo() }.disabled(controller.document?.canRedo != true)
                Button("Save edited timeline") { controller.save() }.disabled(!controller.unsaved)
                Button(controller.unsaved ? "Discard and close":"Done") { controller.browser?.stop();controller.discard();dismiss() }
            }.padding(14)
            HStack(alignment:.top,spacing:18) {
                VStack(alignment:.leading,spacing:7) {
                    Text("CONNECTED AUDIO").font(.caption.weight(.semibold))
                    if controller.cues.isEmpty { Text("This saved cut has no connected audio effects to replace.").font(.caption) }
                    ForEach(controller.cues) { cue in
                        Button { controller.selectCue(cue.id) } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(cue.name).font(.callout.weight(.semibold))
                                Text("Frame \(cue.timelineStartFrame) · \(cue.durationFrames) frames · trim \(cue.sourceStartFrame)").font(.caption.monospacedDigit())
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                        }.buttonStyle(ClautoInlineButtonStyle(selected:cue.id==controller.selectedCueID))
                    }
                }.frame(width:300)
                VStack(alignment:.leading,spacing:7) {
                    Text("Browse and audition candidates; Replace is explicit. Existing timing, trim, gain and fades stay fixed. Shorter candidates are refused; longer ones use the existing range.").font(.caption)
                    Toggle("Similar candidates",isOn:$controller.similarOnly).toggleStyle(.checkbox)
                    Text("Similarity ranks category, tags and required duration. It is not a learned acoustic model.").font(.caption).foregroundStyle(.secondary)
                    if let issue=controller.issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if let folder=controller.savedFolder {
                        HStack { Text("Edited FCPXML saved separately. The saved movie and main cut remain unchanged.").font(.caption);Button("Reveal timeline") { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("timeline.fcpxml")]) } }
                    }
                }
            }.padding(14)
            Divider()
            if let browser=controller.browser {
                SoundBrowserView(store:browser,selectionActionTitle:"Replace selected sound",onSelection:controller.replace)
            } else { ContentUnavailableView("Sound catalog unavailable",systemImage:"waveform.slash") }
        }.frame(minWidth:1100,minHeight:780).task { await controller.load() }
            .interactiveDismissDisabled(controller.unsaved)
            .onDisappear { controller.browser?.stop() }
    }
}
