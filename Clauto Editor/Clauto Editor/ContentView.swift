import SwiftUI

struct ContentView: View {
    @Bindable var store: EditorStore
    var initialTranscriptReviewGates = false
    var initialProjectTab = "Brief"
    @State private var playbackRouter = ReviewWindowRouter()
    @State private var showNewProject = false
    @State private var showSetup = false
    @State private var projectName = ""
    @State private var coverProject: Project?
    @State private var newProjectCover: Project?
    @State private var groupDraft: ProjectGroupEditorDraft?
    @State private var availability = ProjectAvailabilityMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            projectRail.frame(width: 226).accessibilityIdentifier("projectRail")
            VStack(spacing: 0) {
                ForEach(Array(store.voiceReviews.values.filter(\.showsLiveFeedback)), id: \.project.id) { controller in
                    HStack {
                        VoiceLiveFeedbackView(controller: controller).accessibilityIdentifier("globalLiveFeedback")
                        Spacer()
                        if controller.active {
                            Button("Mic Off") { Task { _ = await controller.stop() } }.disabled(controller.mode == .finishing)
                                .accessibilityIdentifier("voiceReviewGlobalStop")
                        } else {
                            Button("Retry Save") { Task { await controller.retryStorage() } }.disabled(controller.pendingWrites > 0)
                                .accessibilityIdentifier("voiceReviewGlobalRetrySave")
                        }
                    }.padding(12).background(ClautoDesign.soft).accessibilityElement(children: .contain)
                }
                if let notice = store.notice {
                    HStack(alignment: .top, spacing: 12) {
                        ClautoIcon(.conversation, size: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.noticeTitle).font(ClautoDesign.type(14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                            ScrollView { Text(notice).font(ClautoDesign.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 76).scrollIndicators(.hidden)
                        }
                        Spacer()
                        ClautoAction("Dismiss", icon: .close, kind: .quiet) { store.notice = nil }
                    }.padding(16).background(ClautoDesign.soft).accessibilityElement(children: .contain)
                }
                if let project = store.selected {
                    ProjectView(store: store, project: project, playbackRouter: playbackRouter, initialTab: initialProjectTab, initialTranscriptReviewGates: initialTranscriptReviewGates).id(project.id.uuidString+":"+project.folder.path)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        ClautoEmpty(title: "New project", detail: "")
                        HStack {
                            ClautoAction("Create a project", icon: .add, kind: .primary) { showNewProject = true }
                            ClautoAction("Check the workspace", icon: .settings) { showSetup = true }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background { ClautoThemeSurface() }
        }.font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).tint(ClautoDesign.citron).textSelection(.enabled)
            .buttonStyle(ClautoButtonStyle()).scrollIndicators(.hidden).clautoThemeAppearance()
            .background(PlaybackWindowRegistration(router: playbackRouter).frame(width: 0,height: 0))
            .onAppear { playbackRouter.store = store; playbackRouter.tab = initialProjectTab; if store.needsFirstWorkspaceSetup { showSetup = true } }
            .onChange(of: playbackRouter.tab) { _, value in store.rememberProjectTab(value) }
            .sheet(isPresented: $playbackRouter.paletteVisible,onDismiss: { playbackRouter.finishPalette() }) { EditorCommandPalette(router: playbackRouter).clautoThemeAppearance() }
            .sheet(isPresented: $playbackRouter.showTimecode) { ReviewTimecodeEntry(router: playbackRouter).clautoThemeAppearance() }
            .sheet(item: Binding(get: { playbackRouter.inlineDrawing ? nil:playbackRouter.editor },set: { value in if !playbackRouter.inlineDrawing { playbackRouter.editor = value } })) { controller in
                FrameCommentEditor(controller: controller, close: { playbackRouter.dismissEditor() })
                    .interactiveDismissDisabled()
            }
            .navigationTitle(store.selected.map { store.libraryName(for: $0)+" — Clauto Video" } ?? "Clauto Video")
            .sheet(item: $coverProject) { project in ProjectCoverEditor(library: store.covers,projectID: project.id,name: store.libraryName(for: project)) }
            .sheet(item: $groupDraft) { draft in ProjectGroupEditor(store: store,draft: draft) }
            .onChange(of: playbackRouter.tab) { _, tab in if tab != "Cut" { playbackRouter.inlineDrawing = false } }
            .onChange(of: store.selectedID) {
                playbackRouter.inlineDrawing = false
                playbackRouter.tab = store.initialProjectTab
            }
            .sheet(isPresented: $showSetup) {
                VStack(spacing: 0) {
                    SetupView(store: store)
                    ClautoRule()
                    HStack { Spacer(); ClautoAction("Done", icon: .check, kind: .primary) { showSetup = false }.keyboardShortcut(.cancelAction) }.padding(20)
                }.frame(width: 680, height: 660).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink)
                    .buttonStyle(ClautoButtonStyle()).clautoThemeAppearance()
            }
            .sheet(isPresented: $showNewProject,onDismiss: {
                if let project = newProjectCover { coverProject = project;newProjectCover = nil }
            }) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { ClautoIcon(.project, size: 25); Text("Start a new project").font(ClautoDesign.heading) }
                    ClautoField(label: "Project name", text: $projectName, placeholder: "A name you’ll recognize").accessibilityIdentifier("projectName")
                    ClautoDisclosure("Details") { Text(store.projectRoot.path).font(ClautoDesign.caption).textSelection(.enabled) }
                    if store.working { ClautoActivity(label: "Creating your project…") }
                    if let notice = store.notice { Text(notice).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        ClautoAction("Cancel", kind: .quiet) { showNewProject = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        ClautoAction("Create project", icon: .add, kind: .primary) {
                            Task { if await store.create(projectName) { newProjectCover = store.selected;showNewProject = false; projectName = "" } }
                        }.disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.working)
                            .keyboardShortcut(.defaultAction).accessibilityIdentifier("createProject")
                    }
                }.padding(32).frame(width: 530).font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).background(ClautoDesign.paper).clautoThemeAppearance()
            }
    }

    private var projectRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClautoWindowControls().padding(.horizontal, 24).padding(.top, 18)
            HStack(spacing: 12) {
                ClautoEmblem(bracketColor: ClautoDesign.railText, stripColor: ClautoDesign.citron).frame(width: 38, height: 38)
                Text("Clauto Video").font(ClautoDesign.type(21, weight: .semibold)).tracking(-0.5).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 30)
            Text("Projects").accessibilityAddTraits(.isHeader).font(ClautoDesign.type(13, weight: .semibold)).foregroundStyle(ClautoDesign.railText).padding(.horizontal, 24).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.libraryEntries) { entry in
                        let selected = store.selectedID.map { entry.memberIDs.contains($0) } ?? false
                        let opened = store.projects.filter { entry.memberIDs.contains($0.id) }
                        let folderPath = opened.first?.folder.path ?? store.projectBookmarks.first(where: { entry.memberIDs.contains($0.projectID) })?.path
                        let place = folderPath.flatMap { availability.availability(forProjectFolder: $0) }
                        let linkedLibrary = folderPath.flatMap { availability.library(forProjectFolder: $0) }
                        Button { Task { await store.selectLibraryEntry(entry) } } label: {
                            HStack(alignment: .center,spacing: 10) {
                                ProjectCoverView(library: store.covers,projectIDs: (selected ? [store.selectedID!]:[])+entry.memberIDs)
                                VStack(alignment: .leading,spacing: 6) {
                                    HStack(alignment: .firstTextBaseline,spacing: 6) {
                                        Text(entry.name).font(ClautoDesign.type(14,weight: .medium)).lineLimit(3)
                                        if let place {
                                            // Instantly available projects get the Mac mark; NAS-only
                                            // projects the server mark. Copying dims the Mac mark.
                                            ClautoIcon(place == .onNAS ? .nas:.local,size: 13)
                                                .opacity(place == .copying ? 0.45:1)
                                                .help(place == .onThisMac ? "On this Mac: opens instantly":place == .onNAS ? "On the NAS: right-click → Open in Final Cut to bring it here":"Copying to this Mac…")
                                                .accessibilityIdentifier("projectAvailability-"+place.rawValue)
                                        }
                                    }
                                    Text(entry.memberIDs.count > 1 ? "\(entry.memberIDs.count) versions":opened.first.flatMap { store.currentCuts[$0.id] }.map { "Cut v\($0.number)" } ?? (opened.isEmpty ? "Unavailable":"Draft")).font(ClautoDesign.caption)
                                    if opened.isEmpty { Text("Reconnect project drive").font(ClautoDesign.caption) }
                                }.frame(maxWidth: .infinity,alignment: .leading)
                            }.padding(10).foregroundStyle(selected ? ClautoDesign.onAccent:ClautoDesign.railText)
                                .background(selected ? ClautoDesign.citron:.clear,in: ClautoThemedShape(palette: ClautoThemeStore.shared.palette))
                        }.buttonStyle(ClautoInlineButtonStyle(onRail: true))
                            .accessibilityLabel(entry.name).accessibilityAddTraits(selected ? .isSelected:[])
                            .accessibilityValue((opened.isEmpty ? "Unavailable. Reconnect the project drive.":entry.memberIDs.count > 1 ? "\(entry.memberIDs.count) versions":"Available")+(place.map { ". Final Cut library: \($0.label)" } ?? ""))
                            .accessibilityIdentifier(entry.groupID == nil ? "project-"+entry.id.uuidString:"project-group-"+entry.id.uuidString)
                            .contextMenu {
                                if let project = opened.first(where: { $0.id == store.selectedID }) ?? opened.first {
                                    Button("Edit illustrated cover…") { coverProject = project }
                                    Button("Group project versions…") { groupDraft = .init(projectIDs: entry.memberIDs,name: entry.name) }
                                    if entry.groupID != nil { Button("Keep this version as a separate project") { store.ungroupProject(project.id) } }
                                }
                                if let linkedLibrary,let place {
                                    Divider()
                                    switch place {
                                    case .onNAS: Button("Start working on \(linkedLibrary.name) here") { availability.startWorkingHere(linkedLibrary.name) }
                                    case .onThisMac:
                                        Button("Open in Final Cut") { availability.startWorkingHere(linkedLibrary.name) }
                                        Button("Hand off to Nathan") { availability.handOffToNathan(linkedLibrary.name) }
                                    case .copying: Button(availability.progress ?? "Working on it…") {}.disabled(true)
                                    }
                                }
                            }
                        // The one action that matters for this project, spelled out, under
                        // the selected project (and under any project mid-handoff).
                        if let linkedLibrary,let place,selected || place == .copying {
                            VStack(alignment: .leading,spacing: 6) {
                                switch place {
                                case .onNAS:
                                    ClautoAction("Start working on \(linkedLibrary.name) here",icon: .local,kind: .primary) { availability.startWorkingHere(linkedLibrary.name) }
                                case .onThisMac:
                                    ClautoAction("Hand off to Nathan",icon: .nas,kind: .primary) { availability.handOffToNathan(linkedLibrary.name) }
                                    ClautoAction("Open in Final Cut",kind: .quiet) { availability.startWorkingHere(linkedLibrary.name) }
                                case .copying:
                                    Text(availability.progress ?? "Working on it…").font(ClautoDesign.caption).fixedSize(horizontal: false,vertical: true)
                                }
                            }.disabled(availability.runningLibrary != nil && place != .copying)
                                .padding(.horizontal,10).padding(.bottom,6).frame(maxWidth: .infinity,alignment: .leading)
                                .accessibilityElement(children: .contain).accessibilityIdentifier("projectHandoff")
                        }
                    }
                    ForEach(store.unopenedProjectIssues.filter { issue in !store.projectBookmarks.contains(where: { $0.path == issue.path }) }) { issue in
                        Button { Task { await store.open(URL(fileURLWithPath: issue.path,isDirectory: true)) } } label: {
                            VStack(alignment: .leading,spacing: 5) { Text(store.projectName(for: issue));Text("Unavailable · retry opening").font(ClautoDesign.caption) }.padding(12)
                        }.buttonStyle(ClautoInlineButtonStyle(onRail: true))
                    }
                    if store.projects.isEmpty && store.unopenedProjectIssues.isEmpty && !store.discoveringProjects {
                        Text("No projects found. Create a project or open an existing project folder.").font(ClautoDesign.caption).padding(12)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 4) {
                if let warning = store.storage.summaryWarning {
                    Text(warning).font(ClautoDesign.caption).padding(8).accessibilityIdentifier("storageSpaceWarning")
                }
                if store.projectRootIssue != nil {
                    Text("Project folder unavailable. Saved projects stay listed.").font(ClautoDesign.caption).padding(8)
                        .help(store.projectRootIssue ?? "")
                }
                railAction(store.discoveringProjects ? "Finding projects…" : "Refresh projects", icon: .open) { Task { await store.restore() } }
                    .disabled(store.discoveringProjects).accessibilityIdentifier("refreshProjects")
                railAction("New project", icon: .add) { showNewProject = true }.keyboardShortcut("n")
                railAction("Open project", icon: .open) { Task { if let folder = await FileDialogs.folder(initial: store.projectRoot) { await store.open(folder) } } }.keyboardShortcut("o")
                railAction("Import cover set",icon: .files) { Task {
                    if let file = await FileDialogs.files().first {
                        await store.covers.importPack(file,known: Set(store.projects.map(\.id)+store.projectBookmarks.map(\.projectID)))
                        if let issue = store.covers.issue { store.notice = issue }
                    }
                } }
                railAction("Workspace", icon: .settings) { showSetup = true }
            }.padding(.horizontal, 16).padding(.bottom, 22)

        }.foregroundStyle(ClautoDesign.railText).background(ClautoDesign.rail)
            .onAppear { availability.startWatching() }
            .onChange(of: availability.failure) { _,failure in
                guard let failure else { return }
                store.notice = failure; availability.clearFailure()
            }
            .onChange(of: availability.message) { _,message in
                guard let message else { return }
                store.notice = message; store.noticeTitle = "Done"; availability.clearMessage()
            }
    }
    private func railAction(_ title: String, icon: ClautoIconName, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 10) { ClautoIcon(icon, size: 17); Text(title) }.padding(.horizontal, 8).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(ClautoInlineButtonStyle(onRail: true)).font(ClautoDesign.type(13, weight: .medium)).foregroundStyle(ClautoDesign.railText)
    }
}

struct ProjectGroupEditorDraft: Identifiable {
    let id = UUID()
    var projectIDs: [UUID]
    var name: String
}
private struct ProjectGroupEditor: View {
    @Bindable var store: EditorStore
    let draft: ProjectGroupEditorDraft
    @Environment(\.dismiss) private var dismiss
    @State private var ids: Set<UUID>
    @State private var name: String
    init(store: EditorStore,draft: ProjectGroupEditorDraft) { self.store = store;self.draft = draft;_ids = State(initialValue: Set(draft.projectIDs));_name = State(initialValue: draft.name) }
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("One project, its versions").font(.title2)
            TextField("Project name",text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("projectGroupName")
            Text("Choose the versions that belong together. Each keeps its original folder, source links, current cut and review history.").font(.caption)
            ForEach(store.projects) { project in
                Toggle(project.manifest.name,isOn: Binding(get: { ids.contains(project.id) },set: { if $0 { ids.insert(project.id) } else { ids.remove(project.id) } }))
                    .accessibilityIdentifier("groupMember-"+project.id.uuidString)
            }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction);Spacer();Button("Group versions") { store.groupProjects(Array(ids),name: name);dismiss() }.disabled(ids.count<2 || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveProjectGroup") }
        }.padding(26).frame(width: 580)
    }
}
