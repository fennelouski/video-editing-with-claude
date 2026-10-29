import SwiftUI

/// Three independently scrolling panes; note growth cannot resize the video.
struct ReviewWorkspace: View {
    @Bindable var store: EditorStore
    let project: Project
    let router: ReviewWindowRouter
    @State private var versionID: UUID?
    @State private var assemblyID: UUID?
    @State private var assets = true
    @State private var feedback = true
    @State private var building = false
    @State private var exportingVersion: CutVersion?
    @State private var soundEditing = false
    @State private var assetPreview: ProjectAssetPreview?
    @State private var focusGeneration = UUID()
    @State private var workspaceWidth: CGFloat = 0
    @FocusState private var pane: Pane?
    private enum Pane: Hashable { case assets, video, feedback }
    private var versions: [CutVersion] { store.cutVersions[project.id] ?? [] }
    private var selected: CutVersion? { versions.first { $0.id == versionID } ?? store.currentCuts[project.id] ?? (store.currentCutIssues[project.id] == nil ? versions.last:nil) }
    private var scripts: ScriptWorkspaceController { store.scriptWorkspace(for: project) }
    private var selectedAssembly: ScriptAssemblyReview? {
        guard !scripts.busy, scripts.session?.state.reviewInProgress != true, scripts.failure == nil, scripts.assemblyFailure == nil else { return nil }
        if let assemblyID { return scripts.assemblies.first { $0.id == assemblyID } }
        return selected == nil ? scripts.assemblies.last : nil
    }
    var body: some View {
        GeometryReader { geometry in
            let showAssets = assets && (geometry.size.width>=760 || !feedback)
            VStack(spacing: 0) {
                HStack {
                    Button {
                        if geometry.size.width<760,!showAssets { assets = true;feedback = false } else { assets.toggle() }
                    } label: { ClautoIcon(.files) }.accessibilityLabel("Toggle assets and versions").clautoHelp("Assets and versions")
                    Text(selectedAssembly.map { "Script assembly · \($0.record.title)" } ?? selected.map { "v\($0.number) · \($0.label)" } ?? "Review").lineLimit(1).textSelection(.enabled)
                    Spacer()
                    Button("Commands…") { router.perform(.palette,explicitControl: true) }
                    Menu("Build / export…") {
                        Button(store.currentCuts[project.id].map { "Project build · current v\($0.number)…" } ?? "Project build…") { building = true }
                        if selectedAssembly == nil,let selected { Button("Export watched v\(selected.number)…") { exportingVersion = selected } }
                    }
                    Button("Script") { router.tab = "Script" }.accessibilityIdentifier("cutOpenScript")
                    Button("Sounds…") {
                        for session in store.reviewPlayers.values where session.ownerID==router.id && session.project.id==project.id { session.control.pause() }
                        soundEditing = true
                    }.disabled(selected == nil || selectedAssembly != nil).accessibilityIdentifier("editTimelineSounds")
                    Button { feedback.toggle() } label: { ClautoIcon(.conversation) }.accessibilityLabel("Toggle feedback").clautoHelp("Feedback")
                }.padding(10)
                if let issue = store.currentCutIssues[project.id] {
                    Text(issue).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled).padding(10).accessibilityIdentifier("unresolvedCurrentCut")
                }
                if let selected,!CutVersionPresentation(selected).restrictions.isEmpty {
                    Text(CutVersionPresentation(selected).restrictions.joined(separator: " · ")).font(ClautoDesign.type(13,weight: .semibold)).foregroundStyle(ClautoDesign.ember).padding(8)
                }
                if selectedAssembly == nil,selected?.artifacts.contains("inputs/import-binding.json") == true {
                    Text("Rendered review movie · original editable source layers are not included. Source attachments are retained references, not new script or fact approval.")
                        .font(ClautoDesign.caption).frame(maxWidth: .infinity,alignment: .leading).padding(10).accessibilityIdentifier("renderedReviewNotice")
                }
                ClautoRule()
                HStack(spacing: 0) {
                    if showAssets {
                        ScrollView {
                            VStack(alignment: .leading,spacing: 14) {
                                Text("Versions").font(.headline)
                                Button("Import verified review…") { Task {
                                    if let packet = await FileDialogs.files().first { await store.importVerifiedReview(packet,project: project) }
                                } }.disabled(store.working).accessibilityIdentifier("importVerifiedReview")
                                ForEach(versions) { version in
                                    let display = store.versionPresentation(version,projectID: project.id)
                                    Button { assemblyID = nil; versionID = version.id } label: {
                                        VStack(alignment: .leading,spacing: 4) {
                                            HStack {
                                                Text("v\(version.number)").font(.caption.monospacedDigit().weight(.semibold))
                                                if store.currentCuts[project.id]?.id == version.id { Text("Current").font(.caption2) }
                                                if selectedAssembly == nil,version.id == selected?.id { Text("Watched").font(.caption2) }
                                            }
                                            Text(display.editorialLabel).lineLimit(2).frame(maxWidth: .infinity,alignment: .leading)
                                            ForEach(display.restrictions,id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(ClautoDesign.ember).fixedSize(horizontal: false,vertical: true) }
                                            if display.importedMovie { Text("Imported movie · source layers absent").font(.caption2).foregroundStyle(ClautoDesign.quiet) }
                                        }.padding(.vertical,4)
                                    }.buttonStyle(ClautoInlineButtonStyle(selected: selectedAssembly == nil && version.id == selected?.id))
                                        .disabled(router.editor != nil)
                                        .accessibilityLabel("v\(version.number) · \(display.fullLabel)")
                                        .accessibilityValue([store.currentCuts[project.id]?.id == version.id ? "Current":"",selectedAssembly == nil && selected?.id == version.id ? "Watched":""].filter { !$0.isEmpty }.joined(separator: ", "))
                                        .help(display.fullLabel)
                                        .accessibilityAddTraits(version.id == selected?.id ? .isSelected : [])
                                }
                                ForEach(store.cutVersionIssues[project.id] ?? []) { issue in
                                    VStack(alignment: .leading,spacing: 4) {
                                        Text(issue.folder+" · unavailable").font(.caption.weight(.semibold))
                                        Text(issue.detail).font(.caption).textSelection(.enabled)
                                    }.foregroundStyle(ClautoDesign.ember).accessibilityElement(children: .combine)
                                }
                                if scripts.busy {
                                    Text("Checking script assemblies…").font(ClautoDesign.caption)
                                } else if scripts.session?.state.reviewInProgress == true {
                                    Text("Finish the blind Script comparison to review assembly history.").font(ClautoDesign.caption)
                                } else if let failure = scripts.failure ?? scripts.assemblyFailure {
                                    Text(failure).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                                    Button("Reload script assemblies") { Task { await scripts.load() } }
                                } else if !scripts.assemblies.isEmpty {
                                    ClautoRule()
                                    Text("Script assemblies").font(.headline).accessibilityAddTraits(.isHeader)
                                    ForEach(scripts.assemblies.reversed()) { assembly in
                                        Button {
                                            for session in store.reviewPlayers.values where session.ownerID == router.id && session.project.id == project.id { session.control.pause() }
                                            assemblyID = assembly.id
                                        } label: {
                                            Text(assembly.record.title).frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(ClautoInlineButtonStyle(selected: selectedAssembly?.id == assembly.id))
                                            .disabled(router.editor != nil).accessibilityIdentifier("scriptAssemblyHistoryItem")
                                    }
                                }
                                ClautoRule(); Text("Assets").font(.headline)
                                ForEach(project.manifest.files) { file in
                                    Button { assetPreview = .init(id: file.id,title: file.name,url: project.folder.appendingPathComponent(file.relativePath)) } label: {
                                        HStack { Image(systemName: "doc");Text(file.name).lineLimit(2);Spacer() }.font(ClautoDesign.caption).frame(maxWidth: .infinity,alignment: .leading).padding(.vertical,5).contentShape(Rectangle())
                                    }.buttonStyle(ClautoInlineButtonStyle())
                                        .disabled(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent(file.relativePath).path))
                                        .accessibilityLabel("Preview "+file.name).accessibilityIdentifier("cutPreviewAsset-"+file.id.uuidString)
                                }
                            }.padding(12)
                        }.focusable().focused($pane,equals: .assets).frame(width: geometry.size.width >= 1100 ? 200 : 160)
                            .overlay(Rectangle().stroke(pane == .assets ? ClautoDesign.ink:.clear,lineWidth: 2).allowsHitTesting(false).accessibilityHidden(true))
                        Divider()
                    }
                    if let assembly = selectedAssembly {
                        ScriptAssemblyReviewPane(assembly: assembly, project: project, openScript: {
                            scripts.requestedVersionID = assembly.record.versionID; router.tab = "Script"
                        }, openStudio: { router.tab = "Studio" })
                    } else if let version = selected,
                       let artifact = version.preferredArtifact(".preview.mp4") ?? version.preferredArtifact(".mp4") {
                        let url = project.folder.appendingPathComponent("cuts/"+version.folderName).appendingPathComponent(artifact)
                        ReviewVersionWorkspace(store: store,project: project,version: version,url: url,router: router,feedbackVisible: feedback,
                            rightWidth: geometry.size.width >= 1100 ? 320 : 260,focus: pane == .video ? .video : pane == .feedback ? .feedback : nil,focusGeneration: focusGeneration)
                            .id(version.id)
                    } else {
                        VStack(spacing: 18) { Image(systemName: "film").font(.largeTitle); Text("No saved version"); Button("Make a cut…") { building = true } }
                            .frame(maxWidth: .infinity,maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
            }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { workspaceWidth = $0 }
        }.background { ClautoThemeSurface() }.textSelection(.enabled)
            .sheet(item: $assetPreview) { item in ProjectAssetPreviewView(item: item) }
            .onAppear { if let id = router.returnVersionID { versionID = id; router.returnVersionID = nil }; router.onWorkspaceCommand = handle;updateCommandContext() }
            .onChange(of: router.returnVersionID) { if let id = router.returnVersionID { versionID = id; router.returnVersionID = nil } }
            .onChange(of: selected?.id) {
                // An externally selected version must never hide an owned
                // draft. Keep its Save/Cancel route in the existing editor.
                if let draft = router.editor?.draft,draft.request.target.versionID != selected?.id { router.inlineDrawing = false }
                updateCommandContext()
            }
            .onChange(of: selectedAssembly?.id) { updateCommandContext() }
            .onChange(of: versions.map(\.id)) { updateCommandContext() }
            .onDisappear { router.onWorkspaceCommand = nil;router.workspaceCapabilities = .init() }
            .task {
                await scripts.load()
                if let id = scripts.requestedAssemblyID { assemblyID = id; scripts.requestedAssemblyID = nil }
            }
            .sheet(isPresented: $building) {
                VStack {
                    HStack { Text("Project build and current-cut export").font(.title2); Spacer(); Button("Done") { building = false }.keyboardShortcut(.cancelAction) }.padding()
                    if let selected { Text("Watched review: v\(selected.number). This workspace uses the project's current cut shown below.").font(.caption).padding(.horizontal) }
                    CutView(store: store,playbackRouter: router,showPlayers: false)
                }
                    .frame(minWidth: 780,minHeight: 640).background(ClautoDesign.paper).clautoThemeAppearance()
            }
            .sheet(isPresented:$soundEditing) {
                if let selected { SoundTimelineEditorView(store:store,project:project,version:selected) }
            }
            .sheet(item: $exportingVersion) { version in
                VStack(alignment: .leading,spacing: 16) {
                    HStack { Text("Export watched v\(version.number)").font(.title2);Spacer();Button("Done") { exportingVersion = nil }.keyboardShortcut(.cancelAction) }
                    Text(version.label).font(.caption).textSelection(.enabled)
                    Text("This export is pinned to the selected saved version. It does not change the current cut.").font(.caption)
                    DerivativeView(store: store,project: project,version: version).id(version.id)
                }.padding(24).frame(minWidth: 780,minHeight: 580).clautoThemeAppearance()
            }
    }
    private func updateCommandContext() {
        let rendered = selectedAssembly == nil && selected.map { $0.preferredArtifact(".preview.mp4") != nil || $0.preferredArtifact(".mp4") != nil } == true
        let index = selectedAssembly == nil ? selected.flatMap { version in versions.firstIndex { $0.id == version.id } }:nil
        router.workspaceCapabilities = .init(watchedVersionID: selectedAssembly == nil ? selected?.id:nil,renderedReview: rendered,previousVersion: index.map { $0 > 0 } ?? false,nextVersion: index.map { $0+1 < versions.count } ?? false)
    }
    private func handle(_ command: EditorCommand) {
        switch command {
        case .assetsPane: if workspaceWidth<760,feedback { assets = true;feedback = false } else { assets.toggle() }
        case .feedbackPane: feedback.toggle()
        case .focusAssets: assets = true;if workspaceWidth<760 { feedback = false }; pane = nil; Task { @MainActor in await Task.yield(); pane = .assets }
        case .focusVideo: pane = .video; focusGeneration = UUID()
        case .focusFeedback: feedback = true; pane = .feedback; focusGeneration = UUID()
        case .previousVersion,.nextVersion:
            guard let selected, let index = versions.firstIndex(where: { $0.id == selected.id }) else { return }
            assemblyID = nil
            let next = min(versions.count-1,max(0,index+(command == .previousVersion ? -1:1)))
            versionID = versions[next].id
        default: break
        }
    }
}
struct ReviewVersionWorkspace: View {
    enum Focus: Equatable { case video, feedback }
    let store: EditorStore
    let project: Project
    let version: CutVersion
    let router: ReviewWindowRouter
    let feedbackVisible: Bool
    let rightWidth: CGFloat
    let focus: Focus?
    let focusGeneration: UUID
    @State private var session: ReviewPlayerSession
    @FocusState private var feedbackFocused: Bool
    init(store: EditorStore,project: Project,version: CutVersion,url: URL,router: ReviewWindowRouter,feedbackVisible: Bool,rightWidth: CGFloat,focus: Focus?,focusGeneration: UUID) {
        self.store = store; self.project = project; self.version = version; self.router = router; self.feedbackVisible = feedbackVisible; self.rightWidth = rightWidth; self.focus = focus; self.focusGeneration = focusGeneration
        _session = State(initialValue: store.reviewPlayer(project: project,version: version,url: url,ownerID: router.id))
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if session.presentation.detached {
                        VStack(spacing: 14) { Image(systemName: "rectangle.on.rectangle").font(.largeTitle); Text("Video detached"); Button("Re-embed") { session.presentation.dock() } }.foregroundStyle(.white)
                    } else { StableReviewVideo(presentation: session.presentation) }
                    if !session.ready && session.issue == nil { ProgressView().controlSize(.large) }
                    ReviewDrawingCanvas(session: session,router: router)
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
                if let notice = session.presentationNotice {
                    HStack { Text(notice).font(.caption).textSelection(.enabled); Button("Dismiss") { session.presentationNotice = nil } }.padding(8)
                }
                if let issue = session.issue {
                    HStack { Text(issue).font(.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled);Button("Retry preview") { session.retryPreview() }.disabled(!session.canRetryPreview).accessibilityIdentifier("retryReviewPreview") }.padding(8)
                }
                ReviewDrawingControls(session: session,router: router)
                VStack(spacing: 8) {
                    ClautoSlider(value: Binding(get: { session.playhead },set: { session.control.seek(seconds: $0) }),range: 0...max(1,session.duration),label: "Review playhead").disabled(!session.ready || router.editor != nil)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { transportButtons;Spacer(minLength: 0);timeAndActions;videoMenu }
                        VStack(spacing: 8) {
                            HStack { transportButtons;Spacer(minLength: 0);videoMenu }
                            HStack { timeAndActions;Spacer(minLength: 0) }
                        }
                    }
                }.padding(12).background(ClautoDesign.sheet)
            }.frame(minWidth: 280,maxWidth: .infinity,maxHeight: .infinity)
            if feedbackVisible {
                Divider()
                VStack(spacing: 0) {
                    ScrollView {
                    VStack(alignment: .leading,spacing: 14) {
                        if let voice = session.voice {
                            VoiceReviewView(controller: voice,versionID: version.id,engine: store.engineRoot,selected: voice.isAttached(to: session.id),select: session.selectForVoice,
                                seek: { if router.editor==nil { session.control.seek(seconds: $0) } },prepareCandidatePlayback: { token in
                                    guard voice.isAttached(to: session.id), voice.beginCandidatePlayback(token) else { return false }
                                    session.control.pause(); session.record(.pause); return true
                                },showsLiveFeedback: false)
                        }
                        if let comments = store.frameComments[project.id] {
                            if let dictation = comments.dictation {
                                ForEach(dictation.visibleHistory.filter { $0.request.target.versionID == version.id && !$0.revisions.isEmpty }) { record in
                                    VStack(alignment: .leading,spacing: 6) {
                                        Text("Dictated region · "+ReviewTimecode.label(frame: record.request.frame.frameIndex)).font(.caption.monospacedDigit())
                                        Text(record.transcript).textSelection(.enabled)
                                        Button("Open Dictated Region") { router.recoverDictation(record,project: project) }
                                    }.padding(10).background(ClautoDesign.sheet)
                                }
                            }
                            ForEach(comments.comments.filter { $0.request.target.versionID == version.id }) { comment in
                                VStack(alignment: .leading,spacing: 6) {
                                    Text(ReviewTimecode.label(frame: comment.request.frame.frameIndex)).font(.caption.monospacedDigit())
                                    Text(comment.text).textSelection(.enabled)
                                    HStack {
                                        Button("Go") { if router.editor==nil { session.control.seek(seconds: comment.request.frame.seconds) } }.disabled(router.editor != nil)
                                        Spacer()
                                        Button("Revise") { router.edit(comment,project: project) }
                                    }
                                }.padding(10).background(ClautoDesign.sheet)
                            }
                        }
                    }.padding(12)
                    }
                }.focusable().focused($feedbackFocused).frame(width: rightWidth)
                    .overlay(Rectangle().stroke(feedbackFocused ? ClautoDesign.ink:.clear,lineWidth: 2).allowsHitTesting(false).accessibilityHidden(true))
            }
        }.onAppear { router.intendedVersionID = version.id; session.attach(to: router) }.onDisappear { session.leaveWorkspace() }
            .onChange(of: focusGeneration) { if focus == .video { session.presentation.focus() }; if focus == .feedback { feedbackFocused = true } }
    }
    private var transportButtons: some View {
        HStack(spacing: 6) {
            transport(.back);transport(.previousFrame);transport(.toggle);transport(.nextFrame);transport(.forward)
        }
    }
    private var timeAndActions: some View {
        HStack(spacing: 6) {
            Text(ReviewTimecode.label(frame: max(0,Int(session.playhead*24000/1001)))).font(ClautoDesign.caption.monospacedDigit()).textSelection(.enabled)
            Button("Draw") { session.invoke(.draw) }.disabled(!session.ready || router.editor != nil).accessibilityIdentifier("drawOnVideo")
            transport(.comment)
        }
    }
    private var videoMenu: some View {
        Menu {
            Button(EditorCommand.timecode.title) { session.invoke(.timecode) }
            Button(session.presentation.detached ? "In Editor":"Pop Out") { session.invoke(.detach) }
            Button(EditorCommand.fullScreen.title) { session.invoke(.fullScreen) }
            Button("PiP Controls") { session.invoke(.pictureInPicture) }
            Button("Hide Native Controls") { session.presentation.hideNativeControls() }
        } label: { ClautoIcon(.settings,size: 18) }.menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("Video options")
    }
    private func transport(_ command: EditorCommand) -> some View {
        Button { session.invoke(command) } label: {
            ClautoIcon(command == .toggle ? (session.playing ? .pause:.play) : command == .comment ? .conversation:.seek,size: 18)
                .rotationEffect(.degrees(command == .back || command == .previousFrame ? 180:0)).frame(width: 24,height: 24)
        }
            .buttonStyle(.plain).clautoHelp(command.title+" · "+command.shortcut).accessibilityLabel(command.title).disabled(!session.ready || session.control.seeking || router.editor != nil)
    }
}


/// Both watched surfaces use the same frozen-frame draft. The underlying
/// player remains mounted and paused; the annotation view owns all gestures.
struct ReviewDrawingCanvas: View {
    let session: ReviewPlayerSession
    @Bindable var router: ReviewWindowRouter
    var body: some View {
        if router.inlineDrawing,let controller = router.editor,let draft = controller.draft,
           draft.request.target.projectID==session.project.id,draft.request.target.versionID==session.version.id {
            ZStack {
                FrameAnnotationCanvas(draft: draft,enabled: !controller.saving && draft.frame != nil)
                    .accessibilityIdentifier("videoDrawingCanvas")
                if controller.preparing { ProgressView().accessibilityLabel("Preparing paused frame") }
            }.frame(maxWidth: .infinity,maxHeight: .infinity)
        }
    }
}
struct ReviewDrawingControls: View {
    let session: ReviewPlayerSession
    @Bindable var router: ReviewWindowRouter
    var body: some View {
        if router.inlineDrawing,let controller = router.editor,let draft = controller.draft,
           draft.request.target.projectID==session.project.id,draft.request.target.versionID==session.version.id {
            VStack(alignment: .leading,spacing: 8) {
                HStack {
                    Picker("Drawing tool",selection: Binding(get: { draft.tool },set: { draft.tool = $0;draft.selecting = false })) {
                        Text("Draw").tag(FrameAnnotationKind.freehand)
                        Text("Circle").tag(FrameAnnotationKind.circle)
                        Text("Highlight").tag(FrameAnnotationKind.highlight)
                    }.pickerStyle(.segmented).labelsHidden()
                }.disabled(controller.saving)
                HStack {
                    Button { draft.undo() } label: { ClautoIcon(.arrow,size: 16).rotationEffect(.degrees(180)) }
                        .disabled(!draft.history.canUndo).accessibilityLabel("Undo drawing").clautoHelp("Undo")
                    Button { draft.redo() } label: { ClautoIcon(.arrow,size: 16) }
                        .disabled(!draft.history.canRedo).accessibilityLabel("Redo drawing").clautoHelp("Redo")
                    Spacer(minLength: 0)
                    Button { router.inlineDrawing = false } label: { ClautoIcon(.settings,size: 16) }.accessibilityLabel("Drawing details").clautoHelp("Details")
                }.disabled(controller.saving)
                HStack {
                    TextField("Note",text: Binding(get: { draft.text },set: { draft.text = $0 }),axis: .vertical).lineLimit(1...3).disabled(controller.saving)
                        .accessibilityIdentifier("videoDrawingNote")
                    Button("Cancel") { Task { if await controller.closeDictationAndCancel() { router.dismissEditor() } } }.disabled(controller.saving)
                    Button("Save") { Task { if await controller.save(),controller.draft==nil { router.dismissEditor() } } }
                        .disabled(!controller.canSaveFrameComment).accessibilityIdentifier("saveVideoDrawing")
                }
                if let error = controller.error { Text(error).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled) }
            }.padding(10).background(ClautoDesign.sheet)
        }
    }
}
