import SwiftUI

struct ContentView: View {
    @Bindable var store: EditorStore
    var initialTranscriptReviewGates = false
    var initialProjectTab = "Brief"
    @State private var showNewProject = false
    @State private var showSetup = false
    @State private var projectName = ""

    var body: some View {
        HStack(spacing: 0) {
            projectRail.frame(width: 226)
            VStack(spacing: 0) {
                ForEach(Array(store.voiceReviews.values.filter(\.active)), id: \.project.id) { controller in
                    HStack {
                        Text("Microphone active · \(controller.project.manifest.name) · \(controller.mode.rawValue)").font(ClautoDesign.caption)
                        Spacer()
                        Button("Stop Voice Review") { Task { _ = await controller.stop() } }.disabled(controller.mode == .finishing)
                            .accessibilityIdentifier("voiceReviewGlobalStop")
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
                    ProjectView(store: store, project: project, initialTab: initialProjectTab, initialTranscriptReviewGates: initialTranscriptReviewGates).id(project.id)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        ClautoEmpty(title: "Your next cut starts here.", detail: "Describe the video. Bring your footage. Keep every version while you work toward the right cut.")
                        HStack {
                            ClautoAction("Create a project", icon: .add, kind: .primary) { showNewProject = true }
                            ClautoAction("Check the workspace", icon: .settings) { showSetup = true }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ClautoDesign.paper)
        }.font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).tint(ClautoDesign.rail)
            .buttonStyle(ClautoButtonStyle()).scrollIndicators(.hidden).preferredColorScheme(.light)
            .navigationTitle(store.selected?.manifest.name ?? "Clauto")
            .sheet(isPresented: $showSetup) {
                VStack(spacing: 0) {
                    SetupView(store: store)
                    ClautoRule()
                    HStack { Spacer(); ClautoAction("Done", icon: .check, kind: .primary) { showSetup = false }.keyboardShortcut(.cancelAction) }.padding(20)
                }.frame(width: 680, height: 660).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink)
                    .buttonStyle(ClautoButtonStyle())
            }
            .sheet(isPresented: $showNewProject) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { ClautoIcon(.project, size: 25); Text("Start a new project").font(ClautoDesign.heading) }
                    ClautoField(label: "Project name", text: $projectName, placeholder: "A name you’ll recognize").accessibilityIdentifier("projectName")
                    Text("Saved on your project drive. Add footage after creating it.").font(ClautoDesign.body).foregroundStyle(ClautoDesign.quiet)
                    Text(store.projectRoot.path).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet).textSelection(.enabled)
                    if store.working { ClautoActivity(label: "Creating your project…") }
                    if let notice = store.notice { Text(notice).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        ClautoAction("Cancel", kind: .quiet) { showNewProject = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        ClautoAction("Create project", icon: .add, kind: .primary) {
                            Task { if await store.create(projectName) { showNewProject = false; projectName = "" } }
                        }.disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.working)
                            .keyboardShortcut(.defaultAction).accessibilityIdentifier("createProject")
                    }
                }.padding(32).frame(width: 530).font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).background(ClautoDesign.paper)
            }
    }

    private var projectRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClautoWindowControls().padding(.horizontal, 24).padding(.top, 14)
            HStack(spacing: 12) {
                ClautoEmblem(bracketColor: ClautoDesign.paper, stripColor: ClautoDesign.citron).frame(width: 38, height: 38)
                Text("Clauto").font(ClautoDesign.type(24, weight: .semibold)).tracking(-0.5)
            }.padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 30)
            Text("Projects").accessibilityAddTraits(.isHeader).font(ClautoDesign.type(13, weight: .semibold)).foregroundStyle(ClautoDesign.soft).padding(.horizontal, 24).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.projects) { project in
                        Button { store.selectedID = project.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                ClautoIcon(.project, size: 18).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(project.manifest.name).font(ClautoDesign.type(14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                    Text("\(store.currentCuts[project.id].map { "Cut v\($0.number)" } ?? "Draft") · \(project.manifest.files.count) files").font(ClautoDesign.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(13).foregroundStyle(store.selectedID == project.id ? ClautoDesign.ink : ClautoDesign.paper)
                                .background(store.selectedID == project.id ? ClautoDesign.citron : .clear, in: CutCorner(cut: 7))
                        }.buttonStyle(ClautoInlineButtonStyle(onRail: true)).clipShape(CutCorner(cut: 7))
                            .accessibilityLabel(project.manifest.name).accessibilityAddTraits(store.selectedID == project.id ? .isSelected : [])
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 4) {
                railAction("New project", icon: .add) { showNewProject = true }.keyboardShortcut("n")
                railAction("Open project", icon: .open) { Task { if let folder = await FileDialogs.folder(initial: store.projectRoot) { await store.open(folder) } } }.keyboardShortcut("o")
                railAction("Workspace", icon: .settings) { showSetup = true }
            }.padding(.horizontal, 16).padding(.bottom, 22)
            HStack(spacing: 7) { Rectangle().fill(ClautoDesign.citron).frame(width: 6, height: 6); Text("Originals stay on your drive").font(ClautoDesign.type(11)) }
                .foregroundStyle(ClautoDesign.soft).padding(.horizontal, 24).padding(.bottom, 24)
        }.foregroundStyle(ClautoDesign.paper).background(ClautoDesign.rail)
    }
    private func railAction(_ title: String, icon: ClautoIconName, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 10) { ClautoIcon(icon, size: 17); Text(title) }.padding(.horizontal, 8).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(ClautoInlineButtonStyle(onRail: true)).font(ClautoDesign.type(13, weight: .medium)).foregroundStyle(ClautoDesign.paper)
    }
}
