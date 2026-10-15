import SwiftUI

struct SetupView: View {
    @Bindable var store: EditorStore
    @State private var skip = ""
    @State private var skipError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) { ClautoIcon(.settings, size: 27); Text("Your workspace").font(ClautoDesign.heading) }
                Text("Keep footage and editing files on your project drive. This build checks installed tools; installation and model downloads remain in development.").foregroundStyle(ClautoDesign.quiet)
                Picker("Theme",selection: Binding(get: { ClautoThemeStore.shared.selected },set: { ClautoThemeStore.shared.choose($0) })) {
                    ForEach(ClautoThemeID.allCases) { theme in Text(theme.label).tag(theme) }
                }.accessibilityIdentifier("clautoThemePicker")
                ClautoSection("Folders") {
                    folderRow("Projects", url: store.projectRoot) { store.setFolders(projects: $0) }
                    ClautoRule()
                    folderRow("Editing engine", url: store.engineRoot) { store.setFolders(engine: $0) }
                }
                ClautoChoice(title: "Default export size for new videos", selection: Binding(get: { store.defaultExportResolution }, set: { store.setDefaultExportResolution($0) }), options: ExportResolution.allCases.map { ($0, $0.label) }).accessibilityIdentifier("defaultExportResolution")
                Text("Each video keeps its own size. This default applies when you create a new project.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                ClautoSection("Playback shortcuts") {
                    HStack {
                        TextField("Skip interval in seconds (1–60)",text: $skip).textFieldStyle(.roundedBorder).frame(width: 230)
                            .accessibilityIdentifier("playbackSkipSeconds")
                        Button("Set Skip Interval") {
                            do {
                                guard let seconds = Double(skip) else { throw WorkflowFailure.invalid("Enter a number from 1 to 60 seconds.") }
                                try store.playbackPreferences.setSkip(seconds); skipError = nil
                            } catch { skipError = error.localizedDescription }
                        }
                    }
                    Text("Current skip: \(store.playbackPreferences.skipSeconds) seconds. Choose a player in Cut, then use the Playback menu.").font(ClautoDesign.caption)
                    if let skipError { Text(skipError).foregroundStyle(ClautoDesign.ember) }
                }
                ClautoAction(store.checking ? "Checking workspace…" : "Check workspace", icon: .check, kind: .primary) { Task { await store.checkSetup() } }.disabled(store.checking)
                if store.checking { ClautoActivity(label: "Checking installed tools and project folders…") }
                ForEach(store.setupChecks.sorted { priority($0.state) < priority($1.state) }) { check in
                    HStack(alignment: .top, spacing: 12) {
                        ClautoIcon(check.state == .ready ? .check : .settings, size: 21).foregroundStyle(check.state == .needsAttention ? ClautoDesign.ember : ClautoDesign.rail)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(check.title).font(ClautoDesign.type(14, weight: .semibold)); Spacer(); Text(check.state.rawValue).font(ClautoDesign.caption) }
                            Text(check.detail).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet).textSelection(.enabled)
                        }
                    }.accessibilityElement(children: .combine)
                    ClautoRule()
                }
                Text("Your video house style remains Sage & Oat. All media stays local in this development build.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            }.padding(30)
        }.font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).background(ClautoDesign.paper)
            .buttonStyle(ClautoButtonStyle()).scrollIndicators(.hidden)
            .onAppear { skip = String(store.playbackPreferences.skipSeconds) }
    }
    private func priority(_ state: SetupCheck.State) -> Int {
        switch state { case .needsAttention: 0; case .notChecked: 1; case .ready: 2 }
    }
    private func folderRow(_ title: String, url: URL, set: @escaping (URL) -> Void) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) { Text(title).font(ClautoDesign.type(14, weight: .semibold)); Text(url.path).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet).textSelection(.enabled) }
            Spacer()
            ClautoAction("Choose folder", icon: .folder) { Task { if let folder = await FileDialogs.folder() { set(folder) } } }.accessibilityLabel("Choose \(title) folder")
        }
    }
}
