import SwiftUI
import AVKit

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
                    Text(store.currentCuts[project.id].map { "Current cut v\($0.number) · \($0.label)" } ?? "Draft · add files and approve a script").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal Project", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) }
            }.padding(20)
            Picker("Project view", selection: $tab) {
                Text("Brief").tag("Brief"); Text("Files").tag("Files"); Text("Cut").tag("Cut")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
                .accessibilityIdentifier("projectTabs")
            Divider()
            if tab == "Brief" { BriefView(brief: $draft, store: store, project: project) }
            else if tab == "Files" { FilesView(store: store, project: project) }
            else { CutView(store: store) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Ask Claude about this cut…", text: $message).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Change request").accessibilityIdentifier("changeRequest")
                    Button("Save Request", systemImage: "arrow.down.doc") {
                        let submitted = message
                        Task { if await store.queueRequest(submitted), message == submitted { message = "" } }
                    }.disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach((store.conversations[project.id] ?? []).suffix(3)) { entry in
                    Text(entry.text).font(.callout).textSelection(.enabled)
                    Text(entry.state).font(.caption).foregroundStyle(.secondary)
                }
                Text("Requests are saved with this project. Live Claude calls are disabled for this session; no request or media is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        .onChange(of: draft) { store.save(draft, for: project.id) }
        .task { await store.loadWorkflow() }
    }
}

private struct BriefView: View {
    @Binding var brief: Brief
    @Bindable var store: EditorStore
    var project: Project
    var body: some View {
        Form {
            Section("What is this video about?") {
                TextEditor(text: $brief.about).frame(minHeight: 90).accessibilityLabel("What is this video about?").accessibilityIdentifier("briefAbout")
            }
            Section("Audience & pacing") {
                TextField("Who is it for?", text: $brief.audience)
                TextField("Target length", text: $brief.length)
                DurationBoundsView(store: store, project: project).id(project.id)
                Picker("Export resolution", selection: Binding(get: { project.manifest.outputResolution }, set: { value in
                    let captured = project
                    Task { await store.exportResolution(value, project: captured) }
                })) {
                    ForEach(ExportResolution.allCases) { value in Text(value.label).tag(value) }
                }.disabled(store.working || store.runningProjectID == project.id).accessibilityIdentifier("projectExportResolution")
                if project.manifest.outputResolution == .ultraHD {
                    Text("4K output can enlarge lower-resolution footage. It does not add source detail; review any upscaled shots.").font(.caption).foregroundStyle(.secondary)
                }
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
            Section("Script") {
                TextEditor(text: $brief.script).frame(minHeight: 70).accessibilityLabel("Script")
                Button("Use as approved script") { Task { await store.approveScript(brief.script) } }
                    .disabled(brief.script.isEmpty || store.runningProjectID != nil)
                Text("The engine needs an annotated script. Confirm its wording and factual claims before using it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Things to avoid") { TextField("Avoid", text: $brief.avoid) }
            Text("Changes save to brief.md. House style: cut cardboard, marker on paper, Sage & Oat.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

private struct DurationBoundsView: View {
    @Bindable var store: EditorStore
    var project: Project
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Minimum seconds (optional)", text: $minimum).accessibilityIdentifier("minimumDuration")
                TextField("Maximum seconds (optional)", text: $maximum).accessibilityIdentifier("maximumDuration")
                Button("Apply Limits") {
                    let captured = project
                    do {
                        func value(_ text: String) throws -> Double? {
                            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if text.isEmpty { return nil }
                            guard let seconds = Double(text) else { throw WorkflowFailure.invalid("Enter duration limits as seconds, or leave them blank.") }
                            return seconds
                        }
                        let bounds = VideoDurationBounds(minimum: try value(minimum), maximum: try value(maximum))
                        try bounds.validate(); issue = nil
                        Task { await store.durationBounds(bounds, project: captured) }
                    } catch { issue = error.localizedDescription }
                }.disabled(store.working || store.runningProjectID == project.id)
            }
            Text("Limits apply to new cuts. If complete narration cannot fit, the run stops for review without padding or retiming.")
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
        }
        .onAppear {
            minimum = project.manifest.durationBounds?.minimum.map { String($0) } ?? ""
            maximum = project.manifest.durationBounds?.maximum.map { String($0) } ?? ""
        }
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
                        .disabled(store.working || store.runningProjectID == project.id).accessibilityIdentifier("addFiles")
                }
                Toggle("Copy media into this project", isOn: $copyMedia)
                Text("Media is referenced by default. Scripts and notes are copied so you can edit them; originals stay untouched.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Use Asset Library…") { Task { if let folder = await FileDialogs.folder() { await store.useProjectFolder(folder, key: "assets") } } }
                    Button("Choose Model Cache…") { Task { if let folder = await FileDialogs.folder() { await store.useProjectFolder(folder, key: "model_cache") } } }
                }.disabled(store.runningProjectID != nil)
                Text("An asset library contains textures, fonts, cutouts and foley. Speech models run locally from the chosen cache; missing models stop the run.").font(.caption).foregroundStyle(.secondary)
                ForEach(FileGroup.allCases) { group in
                    GroupBox(group.rawValue) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Choose \(group.rawValue)…") {
                                Task { await store.intake(await FileDialogs.files(), group: group, copy: copyMedia) }
                            }.disabled(store.working || store.runningProjectID == project.id)
                                .accessibilityLabel("Choose files for \(group.rawValue.lowercased())")
                                .accessibilityIdentifier("chooseGroup\(group.rawValue)")
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
                .accessibilityLabel("Reveal \(file.name) in Finder")
            Button("Remove", systemImage: "minus.circle") { Task { await store.remove(file) } }.disabled(store.working || store.runningProjectID == project.id)
                .accessibilityLabel("Remove \(file.name) from project")
        }
    }
}

private struct CutView: View {
    @Bindable var store: EditorStore
    @State private var versionLabel = "First cut"
    @State private var comparison: UUID?
    @State private var primaryID: UUID?
    @State private var narrationIDs: [UUID] = []
    var body: some View {
        ScrollView {
            if let project = store.selected {
                let run = store.runs[project.id]
                let versions = store.cutVersions[project.id] ?? []
                VStack(alignment: .leading, spacing: 20) {
                    Text("Make a first cut").font(.title2.bold())
                    Text("The engine transcribes and cuts locally, then pauses for your graphic-plan review. Original media stays untouched.").foregroundStyle(.secondary)
                    TextField("Name this version", text: $versionLabel).textFieldStyle(.roundedBorder).accessibilityIdentifier("versionLabel")
                    Picker("Narration clip", selection: $primaryID) {
                        Text("Choose a clip").tag(Optional<UUID>.none)
                        ForEach(project.manifest.files.filter { $0.group == .footage }) { file in
                            Text(file.name).tag(Optional(file.id))
                        }
                    }.accessibilityIdentifier("narrationClip")
                    Button("Add Clip to Narration Order") {
                        if let id = primaryID, !narrationIDs.contains(id) { narrationIDs.append(id) }
                    }.disabled(primaryID == nil || primaryID.map { narrationIDs.contains($0) } == true || store.runningProjectID != nil)
                        .accessibilityIdentifier("addNarrationClip")
                    ForEach(Array(narrationIDs.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text("\(index + 1). " + (project.manifest.files.first { $0.id == id }?.name ?? "Unavailable clip"))
                            Spacer()
                            Button("Move Up") { narrationIDs.swapAt(index, index - 1) }.disabled(index == 0 || store.runningProjectID != nil)
                                .accessibilityLabel("Move narration clip \(index + 1) up")
                            Button("Remove") { narrationIDs.removeAll { $0 == id } }.disabled(store.runningProjectID != nil)
                                .accessibilityLabel("Remove narration clip \(index + 1)")
                        }
                    }
                    Text(narrationIDs.isEmpty ? "Choose one clip, or add several in their spoken order. Other footage stays available for b-roll." : "Clips are cut individually, then assembled in this order and listened back again. Review cross-clip takes before approving the plan.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Check Project") { Task { await store.checkProject() } }.disabled(store.checking || store.runningProjectID != nil)
                        Button("Run Current Inputs") { Task { await store.beginCut(label: versionLabel, primaryID: primaryID, narrationIDs: narrationIDs) } }
                            .buttonStyle(.borderedProminent).disabled(store.checking || store.runningProjectID != nil)
                            .accessibilityIdentifier("runInputs")
                        if store.runningProjectID == project.id { Button("Stop") { Task { await store.cancel() } } }
                    }
                    if let summary = store.checkSummary { Text(summary).textSelection(.enabled) }
                    if let run {
                        Text("Run: \(run.state.rawValue)").bold()
                        if let failure = run.failure { Text(failure).foregroundStyle(.secondary) }
                        ForEach(Array(1...5), id: \.self) { stage in
                            let event = run.events.last { $0.stage == stage }
                            HStack {
                                Image(systemName: event?.state == "done" ? "checkmark.circle" : "circle")
                                Text(["Transcribe", "Rough cut", "Plan", "Assets", "Render"][stage - 1])
                                Spacer(); Text(event?.state ?? "Not run").foregroundStyle(.secondary)
                            }
                        }
                        if run.state == .needsReview {
                            Text("Needs your review").font(.headline)
                            Text("Review every graphic, scientific claim, number and timing below. Approval applies only to this saved plan; editing it requires another review.")
                            Text(store.planReviews[project.id] ?? "Plan unavailable").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("Approve Plan & Continue") { Task { await store.continueCut(approve: true) } }.disabled(store.runningProjectID != nil)
                        }
                        ForEach(store.missingPieces[project.id] ?? []) { piece in
                            GroupBox(piece.ref) {
                                VStack(alignment: .leading) {
                                    Text(piece.status == "warn" ? "Needs attention" : "Missing").bold()
                                    Text(piece.notes.joined(separator: "\n"))
                                    Button("Choose Files…") { Task { await store.satisfy(piece, urls: await FileDialogs.files()) } }
                                        .accessibilityLabel("Choose files for missing \(piece.ref)")
                                }
                            }.dropDestination(for: URL.self) { urls, _ in Task { await store.satisfy(piece, urls: urls) }; return true }
                        }
                        if run.state == .needsAssets {
                            Text("Drops are checked by the engine for resolution, alpha and variants before the render can continue.").font(.caption)
                            Button("Check Missing Pieces & Resume") { Task { await store.continueCut(approve: false) } }.disabled(store.runningProjectID != nil)
                        }
                        if run.state == .failed, run.approvedPlanHash != nil {
                            Button("Retry Assets & Render") { Task { await store.continueCut(approve: false) } }.disabled(store.runningProjectID != nil)
                        }
                    }
                    if let current = store.currentCuts[project.id] {
                        Divider(); Text("Current cut: v\(current.number) · \(current.label)").font(.headline)
                        if current.briefChanged(project) {
                            Label("The brief changed since this cut. Run the updated inputs to make a new version.", systemImage: "exclamationmark.circle")
                        }
                        if current.durationBounds != project.manifest.durationBounds {
                            Text("Duration limits changed since this cut. A new run uses the updated limits.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let resolution = current.exportResolution {
                            Text("Saved output: \(resolution.label) · \(current.aspect ?? "16:9")").font(.caption).foregroundStyle(.secondary)
                            if resolution != project.manifest.outputResolution || current.aspect != project.manifest.aspect {
                                Text("Output settings changed since this cut. A new run uses the updated settings.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        versionResults(current, project: project)
                    }
                    if !versions.isEmpty {
                        Divider(); Text("Versions").font(.headline)
                        ForEach(versions) { version in
                            HStack {
                                Text("v\(version.number) · \(version.label)"); Spacer()
                                Button("Compare") { comparison = version.id }
                                Button("Restore") { Task { await store.restoreCut(version) } }.disabled(store.runningProjectID != nil)
                            }
                        }
                        if let compare = versions.first(where: { $0.id == comparison }) {
                            GroupBox("Compare v\(compare.number)") { versionResults(compare, project: project) }
                        }
                    }
                    DisclosureGroup("Details") { Text(store.details.isEmpty ? "No run output yet." : store.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }.padding(24)
            }
        }
    }
    private func versionResults(_ version: CutVersion, project: Project) -> some View {
        let folder = project.folder.appendingPathComponent("cuts/" + version.folderName)
        return VStack(alignment: .leading, spacing: 12) {
            DerivativeView(store: store, project: project, version: version).id(version.id)
            if let preview = version.preferredArtifact(".preview.mp4") ?? version.preferredArtifact(".mp4") {
                VersionReview(store: store, project: project, version: version, url: folder.appendingPathComponent(preview)).id(version.id)
            }
            Text(version.savedSchemaChecked == true ? "The saved timeline passed Final Cut's schema check. Review the import before editing." : "Final Cut's schema check is unverified for this saved cut. Review the timeline import before editing.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(version.artifacts.filter { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }, id: \.self) { artifact in
                Button("Open Timeline in Final Cut") { NSWorkspace.shared.open(folder.appendingPathComponent(artifact)) }
            }
            Button("Reveal Version") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Button("Export Script & Shot List PDF") {
                Task { if let url = await store.exportHandoff(version) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }.disabled(store.exportingPDF)
            ForEach([version.preferredArtifact(".heard.txt"), version.preferredArtifact(".edl.json")].compactMap { $0 }, id: \.self) { artifact in
                DisclosureGroup(artifact.hasSuffix(".heard.txt") ? "Rendered audio read-back" : "Cut points and reasons") {
                    Text((try? String(contentsOf: folder.appendingPathComponent(artifact), encoding: .utf8)) ?? "File unavailable").font(.caption).textSelection(.enabled)
                }
            }
        }
    }
}

@MainActor
private struct CutPreview: NSViewRepresentable {
    let url: URL
    @Binding var playhead: Double
    var seek: ReviewSeek?
    var control: ReviewPlaybackControl
    @MainActor final class Coordinator {
        var owner: CutPreview
        var player: AVPlayer?
        var observer: Any?
        var lastSeek: UUID?
        var generation = UUID()
        init(_ owner: CutPreview) { self.owner = owner }
        func install(_ player: AVPlayer) {
            teardown(); self.player = player
            owner.control.player = player
            let token = generation
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                let seconds = time.seconds
                let coordinator = self
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == token, coordinator.player != nil, seconds.isFinite else { return }
                    coordinator.owner.playhead = max(0, seconds)
                }
            }
        }
        func teardown() {
            if owner.control.player === player { owner.control.player = nil }
            if let observer { player?.removeTimeObserver(observer) }
            generation = UUID(); observer = nil; player?.pause(); player = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        let player = AVPlayer(url: url); view.player = player; context.coordinator.install(player)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.owner = self
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            let player = AVPlayer(url: url); view.player = player; context.coordinator.install(player)
        }
        if let seek, context.coordinator.lastSeek != seek.id {
            context.coordinator.lastSeek = seek.id
            view.player?.seek(to: CMTime(seconds: seek.seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown()
        view.player?.pause()
        view.player = nil
    }
}

private struct ReviewSeek { var id = UUID(); var seconds: Double }
@MainActor private final class ReviewPlaybackControl { weak var player: AVPlayer? }

private struct VersionReview: View {
    @Bindable var store: EditorStore
    var project: Project
    var version: CutVersion
    var url: URL
    @State private var playhead = 0.0
    @State private var seek: ReviewSeek?
    @State private var control = ReviewPlaybackControl()
    @State private var start = "0"
    @State private var end = ""
    @State private var text = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CutPreview(url: url, playhead: $playhead, seek: seek, control: control).frame(height: 240)
            GroupBox("Feedback for v\(version.number)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Use Playhead") {
                            let time = control.player?.currentTime().seconds ?? playhead
                            if time.isFinite { start = String(format: "%.6f", max(0, time)) }
                        }
                            .accessibilityIdentifier("feedbackUsePlayhead")
                        TextField("Start seconds", text: $start).frame(width: 110).accessibilityIdentifier("feedbackStart")
                        TextField("End seconds (optional)", text: $end).frame(width: 160).accessibilityIdentifier("feedbackEnd")
                    }
                    TextField("What should change at this moment?", text: $text, axis: .vertical)
                        .lineLimit(2...5).accessibilityIdentifier("feedbackText")
                    Button("Save Feedback") {
                        let endText = end.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let at = Double(start), endText.isEmpty || Double(endText) != nil else { store.notice = "Enter times in seconds."; return }
                        let submitted = text, submittedEnd = endText.isEmpty ? nil : Double(endText)
                        let submittedVersion = version, submittedProject = project
                        saving = true
                        Task {
                            if await store.addFeedback(submitted, start: at, end: submittedEnd, version: submittedVersion, project: submittedProject), text == submitted { text = "" }
                            saving = false
                        }
                    }.disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveFeedback")
                    ForEach((store.cutFeedback[project.id] ?? []).filter { $0.versionID == version.id }) { entry in
                        HStack(alignment: .top) {
                            Button(entry.endSeconds.map { String(format: "%.3f–%.3fs", entry.startSeconds, $0) } ?? String(format: "%.3fs", entry.startSeconds)) { seek = ReviewSeek(seconds: entry.startSeconds) }
                                .disabled(entry.attachment != .verified)
                                .accessibilityLabel("Go to feedback at \(entry.startSeconds) seconds")
                            VStack(alignment: .leading) {
                                Text(entry.text).textSelection(.enabled)
                                if let end = entry.endSeconds { Text(String(format: "Range %.3f–%.3f seconds", entry.startSeconds, end)).font(.caption).foregroundStyle(.secondary) }
                                Text(entry.resolved ? "Resolved" : "Open").font(.caption).foregroundStyle(.secondary)
                                if entry.attachment != .verified {
                                    Text("Saved version or time range changed. Restore the verified cut to use this feedback.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button(entry.resolved ? "Reopen" : "Resolve") { Task { await store.resolveFeedback(entry.id, resolved: !entry.resolved, project: project) } }
                                .disabled(entry.attachment != .verified)
                        }
                    }
                    Text("Feedback stays attached to this saved version. The cut is unchanged until a reviewed edit applies it.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }
}
