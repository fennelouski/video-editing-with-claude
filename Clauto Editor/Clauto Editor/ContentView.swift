import SwiftUI

struct ContentView: View {
    @Bindable var store: EditorStore
    @State private var showNewProject = false
    @State private var showSetup = false
    @State private var projectName = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedID) {
                Section("Projects") {
                    ForEach(store.projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(project.manifest.name, systemImage: "film.stack")
                            Text("\(store.currentCuts[project.id].map { "Cut v\($0.number)" } ?? "Draft") · \(project.manifest.files.count) files").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(project.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button("New Project", systemImage: "plus") { showNewProject = true }.keyboardShortcut("n")
                    Button("Open Project…", systemImage: "folder") { Task { if let folder = await FileDialogs.folder(initial: store.projectRoot) { await store.open(folder) } } }.keyboardShortcut("o")
                    Button("Setup & Folders", systemImage: "gearshape") { showSetup = true }
                }.buttonStyle(.bordered).padding().frame(maxWidth: .infinity)
            }
        } detail: {
            if let project = store.selected {
                ProjectView(store: store, project: project).id(project.id)
            } else {
                ContentUnavailableView {
                    Label("Make a first cut", systemImage: "film")
                } description: {
                    Text("Start with a project, describe your video, and add your footage.\nOriginal media stays where you keep it.")
                } actions: {
                    Button("New Project") { showNewProject = true }.buttonStyle(.borderedProminent)
                    Button("Check Setup") { showSetup = true }
                }
            }
        }
        .navigationTitle(store.selected?.manifest.name ?? "Clauto Editor")
        .sheet(isPresented: $showSetup) {
            VStack {
                SetupView(store: store)
                Button("Done") { showSetup = false }.keyboardShortcut(.cancelAction).padding(.bottom)
            }.frame(width: 640, height: 660)
        }
        .sheet(isPresented: $showNewProject) {
            VStack(alignment: .leading, spacing: 20) {
                Text("New project").font(.title2.bold())
                TextField("Project name", text: $projectName).textFieldStyle(.roundedBorder).accessibilityIdentifier("projectName")
                Text("Saved in \(store.projectRoot.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Add footage on the Files tab after creating your project.")
                HStack {
                    Button("Cancel") { showNewProject = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Create Project") {
                        Task {
                            if await store.create(projectName) { showNewProject = false; projectName = "" }
                        }
                    }.buttonStyle(.borderedProminent).disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.working)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("createProject")
                }
            }.padding(28).frame(width: 520)
        }
        .alert(store.noticeTitle, isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
}
