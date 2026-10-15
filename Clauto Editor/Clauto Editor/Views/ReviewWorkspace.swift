import SwiftUI

/// Three independently scrolling panes; note growth cannot resize the video.
struct ReviewWorkspace: View {
    @Bindable var store: EditorStore
    let project: Project
    let router: ReviewWindowRouter
    @State private var versionID: UUID?
    @State private var assets = true
    @State private var feedback = true
    @State private var building = false
    @State private var focusGeneration = UUID()
    @FocusState private var pane: Pane?
    private enum Pane: Hashable { case assets, video, feedback }
    private var versions: [CutVersion] { store.cutVersions[project.id] ?? [] }
    private var selected: CutVersion? { versions.first { $0.id == versionID } ?? store.currentCuts[project.id] ?? versions.last }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Button { assets.toggle() } label: { Image(systemName: "sidebar.left") }.accessibilityLabel("Toggle assets and versions").clautoHelp("Assets and versions")
                    Text(selected.map { "v\($0.number) · \($0.label)" } ?? "Review").lineLimit(1).textSelection(.enabled)
                    Spacer()
                    Button("Commands…") { router.perform(.palette,explicitControl: true) }
                    Button("Build…") { building = true }
                    Button { feedback.toggle() } label: { Image(systemName: "sidebar.right") }.accessibilityLabel("Toggle feedback").clautoHelp("Feedback")
                }.padding(10)
                ClautoRule()
                HStack(spacing: 0) {
                    if assets {
                        ScrollView {
                            VStack(alignment: .leading,spacing: 14) {
                                Text("Versions").font(.headline)
                                ForEach(versions) { version in
                                    Button { versionID = version.id } label: {
                                        HStack { Image(systemName: version.id == selected?.id ? "play.circle.fill" : "film"); Text("v\(version.number) · \(version.label)").frame(maxWidth: .infinity,alignment: .leading) }
                                    }.buttonStyle(ClautoInlineButtonStyle(selected: version.id == selected?.id))
                                        .accessibilityAddTraits(version.id == selected?.id ? .isSelected : [])
                                }
                                ClautoRule(); Text("Assets").font(.headline)
                                ForEach(project.manifest.files) { file in
                                    Text(file.name).font(ClautoDesign.caption).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading)
                                }
                            }.padding(12)
                        }.focusable().focused($pane,equals: .assets).frame(width: geometry.size.width >= 1100 ? 200 : 160)
                        Divider()
                    }
                    if let version = selected,
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
            }
        }.background { ClautoThemeSurface() }.textSelection(.enabled)
            .onAppear { if let id = router.returnVersionID { versionID = id; router.returnVersionID = nil }; router.onWorkspaceCommand = handle }
            .onChange(of: router.returnVersionID) { if let id = router.returnVersionID { versionID = id; router.returnVersionID = nil } }
            .onDisappear { router.onWorkspaceCommand = nil }
            .sheet(isPresented: $building) {
                VStack { HStack { Text("Build and export").font(.title2); Spacer(); Button("Done") { building = false }.keyboardShortcut(.cancelAction) }.padding(); CutView(store: store,playbackRouter: router,showPlayers: false) }
                    .frame(minWidth: 780,minHeight: 640).background(ClautoDesign.paper).clautoThemeAppearance()
            }
    }
    private func handle(_ command: EditorCommand) {
        switch command {
        case .assetsPane: assets.toggle()
        case .feedbackPane: feedback.toggle()
        case .focusAssets: assets = true; pane = nil; Task { @MainActor in await Task.yield(); pane = .assets }
        case .focusVideo: pane = .video; focusGeneration = UUID()
        case .focusFeedback: feedback = true; pane = .feedback; focusGeneration = UUID()
        case .previousVersion,.nextVersion:
            guard let selected, let index = versions.firstIndex(where: { $0.id == selected.id }) else { return }
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
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
                if let notice = session.presentationNotice {
                    HStack { Text(notice).font(.caption).textSelection(.enabled); Button("Dismiss") { session.presentationNotice = nil } }.padding(8)
                }
                if let issue = session.issue { Text(issue).font(.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled).padding(8) }
                VStack(spacing: 8) {
                    ClautoSlider(value: Binding(get: { session.playhead },set: { session.control.seek(seconds: $0) }),range: 0...max(1,session.duration),label: "Review playhead").disabled(!session.ready)
                    HStack(spacing: 6) {
                        transport(.back,"gobackward")
                        transport(.previousFrame,"backward.end")
                        transport(.toggle,session.playing ? "pause.fill":"play.fill")
                        transport(.nextFrame,"forward.end")
                        transport(.forward,"goforward")
                        Spacer(minLength: 0)
                        Text(ReviewTimecode.label(frame: max(0,Int(session.playhead*24000/1001)))).font(.caption.monospacedDigit()).textSelection(.enabled)
                        transport(.comment,"plus.bubble")
                        Menu {
                            Button(EditorCommand.timecode.title) { session.invoke(.timecode) }
                            Button(EditorCommand.detach.title) { session.invoke(.detach) }
                            Button(EditorCommand.fullScreen.title) { session.invoke(.fullScreen) }
                            Button(EditorCommand.pictureInPicture.title) { session.invoke(.pictureInPicture) }
                            Button("Hide Native Controls") { session.presentation.hideNativeControls() }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("Video options")
                    }
                }.padding(12).background(ClautoDesign.sheet)
            }.frame(minWidth: 280,maxWidth: .infinity,maxHeight: .infinity)
            if feedbackVisible {
                Divider()
                ScrollView {
                    VStack(alignment: .leading,spacing: 14) {
                        if let voice = session.voice {
                            VoiceReviewView(controller: voice,versionID: version.id,engine: store.engineRoot,selected: voice.isAttached(to: session.id),select: session.selectForVoice,
                                seek: session.control.seek,prepareCandidatePlayback: { token in
                                    guard voice.isAttached(to: session.id), voice.beginCandidatePlayback(token) else { return false }
                                    session.control.pause(); session.record(.pause); return true
                                })
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
                                        Button("Go") { session.control.seek(seconds: comment.request.frame.seconds) }
                                        Spacer()
                                        Button("Revise") { router.edit(comment,project: project) }
                                    }
                                }.padding(10).background(ClautoDesign.sheet)
                            }
                        }
                    }.padding(12)
                }.focusable().focused($feedbackFocused).frame(width: rightWidth)
            }
        }.onAppear { router.intendedVersionID = version.id; session.attach(to: router) }.onDisappear { session.leaveWorkspace() }
            .onChange(of: focusGeneration) { if focus == .video { session.presentation.focus() }; if focus == .feedback { feedbackFocused = true } }
    }
    private func transport(_ command: EditorCommand,_ symbol: String) -> some View {
        Button { session.invoke(command) } label: { Image(systemName: symbol).frame(width: 24,height: 24) }
            .buttonStyle(.plain).clautoHelp(command.title+" · "+command.shortcut).accessibilityLabel(command.title).disabled(!session.ready || session.control.seeking)
    }
}
