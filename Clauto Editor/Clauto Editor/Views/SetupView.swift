import SwiftUI

struct SetupView: View {
    @Bindable var store: EditorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Set up your workspace").font(.title.bold())
                Text("Keep footage and editing files on your project drive. This build checks installed tools; automated installation and model downloads are still in development.")
                    .foregroundStyle(.secondary)
                GroupBox("Folders") {
                    VStack(alignment: .leading, spacing: 12) {
                        folderRow("Projects", url: store.projectRoot) { store.setFolders(projects: $0) }
                        folderRow("Editing engine", url: store.engineRoot) { store.setFolders(engine: $0) }
                    }.padding(8)
                }
                Button(store.checking ? "Checking…" : "Check Setup", systemImage: "checklist") { Task { await store.checkSetup() } }
                    .buttonStyle(.borderedProminent).disabled(store.checking)
                ForEach(store.setupChecks) { check in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(check.state)).foregroundStyle(check.state == .ready ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(check.title).bold(); Spacer(); Text(check.state.rawValue).font(.caption) }
                            Text(check.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.accessibilityElement(children: .combine)
                }
                Text("House style: cut cardboard, marker on paper, Sage & Oat. All media stays local in this development build.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    private func folderRow(_ title: String, url: URL, set: @escaping (URL) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) { Text(title).bold(); Text(url.path).font(.caption).textSelection(.enabled) }
            Spacer()
            Button("Choose…") { Task { if let folder = await FileDialogs.folder() { set(folder) } } }.accessibilityLabel("Choose \(title) folder")
        }
    }
    private func icon(_ state: SetupCheck.State) -> String {
        switch state { case .ready: "checkmark.circle.fill"; case .needsAttention: "exclamationmark.circle"; case .notChecked: "minus.circle" }
    }
}
