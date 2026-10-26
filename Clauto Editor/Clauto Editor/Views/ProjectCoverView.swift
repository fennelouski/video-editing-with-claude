import SwiftUI
import ImagePlayground
import Observation

@MainActor @Observable final class ProjectCoverLibrary {
    private(set) var records: [UUID:ProjectCoverRecord] = [:]
    private(set) var images: [UUID:NSImage] = [:]
    private(set) var issue: String?
    private(set) var busy = false
    private let repository: ProjectCoverRepository
    private let defaults: UserDefaults
    init(defaults: UserDefaults,repository: ProjectCoverRepository = .init()) {
        self.defaults = defaults;self.repository = repository
        if let data = defaults.data(forKey: "ClautoProjectCovers"),let values = try? JSONDecoder().decode([ProjectCoverRecord].self,from: data) { for value in values { records[value.projectID] = value } }
    }
    func load(_ ids: [UUID]) async {
        for id in ids where images[id] == nil {
            if let record = records[id],let data = try? await repository.thumbnail(record) { images[id] = NSImage(data: data) }
        }
    }
    func save(_ source: URL,id: UUID,generator: String,prompt: String,sha: String? = nil) async {
        guard !busy else { return };busy = true;defer { busy = false }
        do {
            let record = try await repository.save(source,projectID: id,generator: generator,prompt: prompt,expectedSHA256: sha)
            var next = records;next[id] = record
            defaults.set(try JSONEncoder().encode(Array(next.values)),forKey: "ClautoProjectCovers");records = next
            images[id] = NSImage(data: try await repository.thumbnail(record));issue = nil
        } catch { issue = error.localizedDescription }
    }
    func importPack(_ url: URL,known: Set<UUID>) async {
        guard !busy else { return }
        do {
            let scope = url.startAccessingSecurityScopedResource();defer { if scope { url.stopAccessingSecurityScopedResource() } }
            let bytes = try SourceRenderDirectory.open(url.deletingLastPathComponent()).read(url.lastPathComponent,limit: 1024*1024)
            try TranscriptJSONKeys.validate(bytes);let pack = try JSONDecoder().decode(ProjectCoverPack.self,from: bytes)
            guard pack.schemaVersion == 1,!pack.entries.isEmpty,pack.entries.count <= 100,Set(pack.entries.map(\.projectID)).count == pack.entries.count,
                  pack.entries.allSatisfy({ known.contains($0.projectID) && $0.imagePath.hasPrefix("/") && TranscriptCatalog.isSHA($0.sha256) }) else { throw ProjectFailure.invalidProject }
            for entry in pack.entries {
                await save(URL(fileURLWithPath: entry.imagePath),id: entry.projectID,generator: entry.generator,prompt: entry.prompt,sha: entry.sha256)
                if issue != nil { return }
            }
        } catch { issue = error.localizedDescription }
    }
}
struct ProjectCoverView: View {
    @Bindable var library: ProjectCoverLibrary
    let projectIDs: [UUID]
    var body: some View {
        Group {
            if let image = projectIDs.compactMap({ library.images[$0] }).first {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack { ClautoDesign.soft;Image(systemName: "photo").foregroundStyle(ClautoDesign.quiet) }
            }
        }.frame(width: 62,height: 48).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
            .task(id: projectIDs) { await library.load(projectIDs) }
    }
}
struct ProjectCoverEditor: View {
    @Bindable var library: ProjectCoverLibrary
    let projectID: UUID
    let name: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var generating = false
    @State private var prompt = ""
    var body: some View {
        VStack(alignment: .leading,spacing: 20) {
            HStack { Text("Project cover").font(.title2);Spacer();Button("Close",systemImage: "xmark") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(name).font(.headline)
            if let image = library.images[projectID] { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 230) }
            TextField("Describe the illustration",text: $prompt,axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...5)
            Text("AI-illustrated cover art identifies the project. It is separate from your footage and saved cuts.").font(.caption)
            HStack {
                Button("Generate AI illustration") { generating = true }.disabled(!supportsImagePlayground || library.busy)
                Button("Import illustration…") { Task { if let image = await FileDialogs.files().first { await library.save(image,id: projectID,generator: "Imported illustration",prompt: prompt) } } }.disabled(library.busy)
            }
            if !supportsImagePlayground { Text("Apple Image Playground is unavailable on this Mac. You can import an AI illustration created with your existing image tools.").font(.caption) }
            if library.busy { ProgressView("Saving cover…") }
            if let issue = library.issue { Text(issue).foregroundStyle(.red) }
            if let record = library.records[projectID] { Text("Source: "+record.generator).font(.caption) }
        }.padding(26).frame(width: 580)
            .onAppear { prompt = "Editorial illustration for \(name), clear central subject, warm natural colors, no words or logos" }
            .imagePlaygroundSheet(isPresented: $generating,concept: prompt) { url in
                Task { await library.save(url,id: projectID,generator: "Apple Image Playground",prompt: prompt) }
            }
    }
}
