import SwiftUI
import SoundBrowserCore
import SoundBrowserUI

struct SoundTimelineEditorView: View {
    let store: EditorStore
    @State private var controller: SoundTimelineController
    @State private var reviewExport: DerivedCut?
    @State private var workspaceOwner = UUID()
    @Environment(\.dismiss) private var dismiss
    init(store:EditorStore,project:Project,version:CutVersion) { self.store=store;_controller=State(initialValue:SoundTimelineController(project:project,version:version)) }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text("Sounds in v\(controller.version.number)").font(.title2.weight(.semibold))
                Spacer()
                Button("Undo replacement") { controller.undo() }.disabled(controller.document?.canUndo != true)
                Button("Redo") { controller.redo() }.disabled(controller.document?.canRedo != true)
                Button("Save edited timeline") { controller.save() }.disabled(!controller.unsaved)
                Button("Create local export") {
                    guard let selection=controller.exportSelection else { return }
                    let request=DerivativeRequest(aspect:controller.project.manifest.aspect,resolution:controller.project.manifest.outputResolution,soundTimelineEdit:selection)
                    Task {
                        await store.exportDerivative(request,version:controller.version,project:controller.project)
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["CLAUTO_SOUND_SILENT_QA"]=="1" { DispatchQueue.main.async { SoundTimelineQAState.capture() } }
                        #endif
                    }
                }.disabled(controller.exportSelection == nil || store.exportingDerivativeProjectID != nil || store.runningProjectID != nil || store.working || store.checking)
                Button(controller.unsaved ? "Discard and close":"Done") { controller.browser?.stop();controller.discard();dismiss() }
            }.buttonStyle(.bordered).tint(ClautoDesign.ink).padding(14)
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
                        HStack { Text("Edited FCPXML saved separately. Create a local export to render its new audio; the parent stays unchanged.").font(.caption);Button("Reveal timeline") { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("timeline.fcpxml")]) } }
                    }
                    if store.exportingDerivativeProjectID==controller.project.id { HStack { ProgressView().controlSize(.small);Text("Rendering edited audio locally…").font(.caption);Button("Stop export") { Task { await store.cancelDerivative() } } } }
                    if let notice=store.notice { Text(notice).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if let selection=controller.exportSelection,let export=(store.derivedCuts[controller.project.id] ?? []).first(where:{ $0.request.soundTimelineEdit==selection }) {
                        Button("Review edited movie") { reviewExport=export }
                    }
                }
            }.buttonStyle(.bordered).tint(ClautoDesign.ink).padding(14)
            Divider()
            if let browser=controller.browser {
                SoundBrowserView(store:browser,selectionActionTitle:"Replace selected sound",onSelection:controller.replace)
            } else { ContentUnavailableView("Sound catalog unavailable",systemImage:"waveform.slash") }
        }.background(Color(nsColor:.windowBackgroundColor)).frame(minWidth:1100,minHeight:780).task { await controller.load() }
            .interactiveDismissDisabled(controller.unsaved)
            .onAppear { store.registerSoundWorkspace(workspaceOwner,projectID: controller.project.id) }
            .onDisappear { controller.browser?.stop();store.unregisterSoundWorkspace(workspaceOwner) }
            .sheet(item:$reviewExport) { export in
                VStack {
                    HStack { Text("Edited audio export").font(.headline);Spacer();Button("Done") { reviewExport=nil } }
                    ClautoVideoViewer(url:controller.project.folder.appendingPathComponent("build/derivatives/"+export.id.uuidString+"/review.mp4"))
                }.padding().frame(width:900,height:600)
            }
    }
}
