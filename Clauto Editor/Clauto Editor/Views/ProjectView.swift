import SwiftUI

struct ProjectView: View {
    @Bindable var store: EditorStore
    var project: Project
    @State private var tab = "Brief"
    // Intentional one-time seed; parent keys this view by project ID when switching projects.
    @State private var draft: Brief
    @State private var message = ""

    init(store: EditorStore, project: Project) {
        self.store = store; self.project = project
        _draft = State(initialValue: project.brief)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.manifest.name).font(.title2.bold())
                    Text("Draft · originals referenced in place").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal Project", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) }
            }.padding(20)
            Picker("Project view", selection: $tab) {
                Text("Brief").tag("Brief"); Text("Files").tag("Files"); Text("Cut").tag("Cut")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            if tab == "Brief" { BriefView(brief: $draft, store: store) }
            else if tab == "Files" { FilesView(store: store, project: project) }
            else { CutView(store: store) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Ask Claude about this cut…", text: $message).textFieldStyle(.roundedBorder)
                    Button("Send", systemImage: "arrow.up") {}.disabled(true)
                }
                Text("Conversation is not available in this development build. Your files stay local.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        .onChange(of: draft) { store.save(draft, for: project.id) }
    }
}

private struct BriefView: View {
    @Binding var brief: Brief
    @Bindable var store: EditorStore
    var body: some View {
        Form {
            Section("What is this video about?") {
                TextEditor(text: $brief.about).frame(minHeight: 90).accessibilityLabel("What is this video about?").accessibilityIdentifier("briefAbout")
            }
            Section("Audience & pacing") {
                TextField("Who is it for?", text: $brief.audience)
                TextField("Target length", text: $brief.length)
                TextField("Tone", text: $brief.tone)
                Picker("Aspect ratio", selection: Binding(get: { store.selected?.manifest.aspect ?? "16:9" }, set: { value in Task { await store.preferences(aspect: value) } })) {
                    Text("16:9 · landscape").tag("16:9"); Text("9:16 · vertical").tag("9:16")
                }.disabled(store.working)
                Picker("Speech model", selection: Binding(get: { store.selected?.manifest.whisperModel ?? "large-v3" }, set: { value in Task { await store.preferences(model: value) } })) {
                    Text("Fast · small").tag("small"); Text("Balanced · medium").tag("medium"); Text("Best · large-v3").tag("large-v3")
                }.disabled(store.working)
            }
            Section("Music & graphics") {
                TextField("Music mood or wishes", text: $brief.music)
                TextField("What should appear on screen?", text: $brief.graphics)
                Text("Use your recordings or licensed files. Missing pieces become a build sheet.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Script") { TextEditor(text: $brief.script).frame(minHeight: 70).accessibilityLabel("Script") }
            Section("Things to avoid") { TextField("Avoid", text: $brief.avoid) }
            Text("Changes save to brief.md. House style: cut cardboard, marker on paper, Sage & Oat.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

private struct FilesView: View {
    @Bindable var store: EditorStore
    var project: Project
    @State private var copyMedia = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Drop footage, recordings, images or scripts").font(.headline)
                    Spacer()
                    Button("Add Files…", systemImage: "plus") { Task { await store.intake(await FileDialogs.files(), copy: copyMedia) } }
                        .disabled(store.working).accessibilityIdentifier("addFiles")
                }
                Toggle("Copy media into this project", isOn: $copyMedia)
                Text("Media is referenced by default. Scripts and notes are copied so you can edit them; originals stay untouched.").font(.caption).foregroundStyle(.secondary)
                ForEach(FileGroup.allCases) { group in
                    GroupBox(group.rawValue) {
                        VStack(alignment: .leading, spacing: 12) {
                            let files = project.manifest.files.filter { $0.group == group }
                            if files.isEmpty { Text("Drop \(group.rawValue.lowercased()) here, or use Add Files.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                            ForEach(files) { file in fileRow(file) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        Task { await store.intake(urls, group: group, copy: copyMedia) }; return true
                    }
                    .accessibilityLabel("\(group.rawValue) drop zone")
                }
            }.padding(24)
        }
        .dropDestination(for: URL.self) { urls, _ in Task { await store.intake(urls, copy: copyMedia) }; return true }
    }
    private func fileRow(_ file: ProjectFile) -> some View {
        let url = project.folder.appendingPathComponent(file.relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).bold()
                Text(exists ? (file.copied ? "Copied into project" : "Referenced in place") : "Missing file — reconnect its drive")
                    .font(.caption).foregroundStyle(.secondary)
                Text(file.originalPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(file.originalPath)
            }
            Spacer()
            if file.group == .audio || file.group == .music {
                Menu(file.needsRole ? "What is this?" : file.group.rawValue) {
                    Button("Music") { Task { await store.assign(.music, file: file) } }
                    Button("Recorded audio") { Task { await store.assign(.audio, file: file) } }
                }.disabled(store.working)
            }
            Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.originalPath)]) }.disabled(!exists)
            Button("Remove", systemImage: "minus.circle") { Task { await store.remove(file) } }.disabled(store.working)
        }
    }
}

private struct CutView: View {
    @Bindable var store: EditorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Prepare your first cut").font(.title2.bold())
                Text("Check your project before editing. This checks files and engine requirements without transcribing or rendering media.").foregroundStyle(.secondary)
                HStack {
                    Button(store.checking ? "Checking…" : "Check Project", systemImage: "checkmark.circle") { Task { await store.checkProject() } }
                        .buttonStyle(.borderedProminent).disabled(store.checking)
                    if store.checking { Button("Stop") { Task { await store.cancel() } } }
                    Button("Run First Cut") {}.disabled(true)
                }
                if let summary = store.checkSummary { Text(summary).textSelection(.enabled) }
                ForEach(["Transcribe", "Rough cut", "Plan", "Assets", "Render"], id: \.self) { stage in
                    HStack { Image(systemName: "circle"); Text(stage); Spacer(); Text("Not run").foregroundStyle(.secondary) }
                }
                Text("Cut generation, missing-piece checklists, science review and previews are still in development. No cut has been generated by this build.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Details") { Text(store.details.isEmpty ? "No project check output yet." : store.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }.padding(24)
        }
    }
}
