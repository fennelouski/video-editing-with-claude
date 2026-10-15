import SwiftUI
import AVKit

struct ProjectView: View {
    @Bindable var store: EditorStore
    var project: Project
    let playbackRouter: ReviewWindowRouter
    private var tab: String { playbackRouter.tab }
    // Intentional one-time seed; parent keys this view by project ID when switching projects.
    @State private var draft: Brief
    @State private var message = ""
    @State private var compactHistoryExpanded = false

    let initialTranscriptReviewGates: Bool
    init(store: EditorStore, project: Project, playbackRouter: ReviewWindowRouter, initialTab: String = "Brief", initialTranscriptReviewGates: Bool = false) {
        self.initialTranscriptReviewGates = initialTranscriptReviewGates
        self.store = store; self.project = project; self.playbackRouter = playbackRouter
        _draft = State(initialValue: project.brief)
        // Navigation belongs to the shared window command router.
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.manifest.name).font(ClautoDesign.heading).lineLimit(2).accessibilityAddTraits(.isHeader)
                        Text(store.currentCuts[project.id].map { "Current cut v\($0.number) · \($0.label)" } ?? "Describe the cut you want to make.")
                            .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    }
                    Spacer(minLength: 10)
                    ClautoAction("Project folder", icon: .folder, kind: .quiet) { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) }
                }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
                HStack {
                    ClautoSegments(selection: Binding(get: { tab },set: { playbackRouter.tab = $0 }), options: [("Brief", .brief), ("Files", .files), ("Transcript", .brief), ("Cut", .cut)]).accessibilityIdentifier("projectTabs")
                    Spacer()
                }.padding(.horizontal, 28).padding(.bottom, 20)
                ClautoRule()
                if geometry.size.width >= 1060 && tab == "Brief" {
                    HStack(spacing: 0) {
                        BriefView(brief: $draft, store: store, project: project)
                        Rectangle().fill(ClautoDesign.rule).frame(width: 1)
                        conversation(compact: false).frame(width: 310).frame(maxHeight: .infinity, alignment: .top).background(ClautoDesign.sheet)
                    }
                } else {
                    Group {
                        if tab == "Brief" { BriefView(brief: $draft, store: store, project: project) }
                        else if tab == "Files" { FilesView(store: store, project: project) }
                        else if tab == "Transcript" { TranscriptReviewView(store: store, project: project, reviewGatesExpanded: initialTranscriptReviewGates) }
                        else { ReviewWorkspace(store: store,project: project,router: playbackRouter) }
                    }.frame(maxHeight: .infinity)
                    if tab != "Transcript" && tab != "Cut" {
                        ClautoRule()
                        conversation(compact: true)
                    }
                }
            }
        }.background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).font(ClautoDesign.body).buttonStyle(ClautoButtonStyle()).scrollIndicators(.hidden)
            .onChange(of: draft) { store.save(draft, for: project.id) }
            .task { await store.loadWorkflow() }
    }
    @ViewBuilder private func conversation(compact: Bool) -> some View {
        let entries = (store.conversations[project.id] ?? []).suffix(3)
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            HStack(spacing: 9) {
                ClautoIcon(.conversation, size: compact ? 17 : 20)
                Text("Work with Claude").font(ClautoDesign.type(compact ? 14 : 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if compact, !entries.isEmpty {
                    Spacer(minLength: 12)
                    Button { compactHistoryExpanded.toggle() } label: {
                        HStack(spacing: 8) { Text("Recent requests · \(entries.count)"); ClautoIcon(.arrow, size: 13).rotationEffect(.degrees(compactHistoryExpanded ? 90 : 0)) }
                            .font(ClautoDesign.caption).padding(.vertical, 5)
                    }.buttonStyle(ClautoInlineButtonStyle()).accessibilityValue(compactHistoryExpanded ? "Expanded" : "Collapsed")
                }
            }
            if !entries.isEmpty {
                if compact {
                    if compactHistoryExpanded { requestHistory(entries).frame(height: 100) }
                } else { requestHistory(entries).frame(maxHeight: .infinity, alignment: .top) }
            } else if !compact {
                Text("Save the change you want to make. Requests remain part of this project.")
                    .font(ClautoDesign.body).foregroundStyle(ClautoDesign.quiet)
                Spacer(minLength: 16)
            }
            if compact {
                HStack(alignment: .bottom, spacing: 12) {
                    requestField
                    saveRequest.fixedSize()
                }
            } else { requestField; saveRequest }
            Text("Claude is offline in this build. Requests stay saved with this project; no media or message is sent.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet).fixedSize(horizontal: false, vertical: true)
        }.padding(compact ? 18 : 22).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var requestField: some View {
        ClautoField(label: "Change request", text: $message, placeholder: "What should change in this cut?")
            .accessibilityIdentifier("changeRequest")
    }
    private var saveRequest: some View {
        ClautoAction("Save request", icon: .conversation, kind: .primary) {
            let submitted = message
            Task { if await store.queueRequest(submitted), message == submitted { message = "" } }
        }.disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func requestHistory(_ entries: ArraySlice<LocalMessage>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.text).font(ClautoDesign.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(entry.state).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet).fixedSize(horizontal: false, vertical: true)
                    }
                    ClautoRule()
                }
            }
        }.scrollIndicators(.hidden)
    }

}

private struct BriefView: View {
    @Binding var brief: Brief
    @Bindable var store: EditorStore
    var project: Project
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ClautoSection("What are we making?", detail: "Give the cut a clear purpose. These notes stay editable as the project evolves.") {
                    ClautoTextArea(text: $brief.about, label: "What is this video about?").frame(height: 136).accessibilityIdentifier("briefAbout")
                }
                ClautoSection("Audience & pacing") {
                    HStack(alignment: .top) { ClautoField(label: "Audience", text: $brief.audience, placeholder: "Who is it for?"); ClautoField(label: "Target length", text: $brief.length, placeholder: "About five minutes") }
                    ClautoField(label: "Tone", text: $brief.tone, placeholder: "How should it feel?")
                    DurationBoundsView(store: store, project: project).id(project.id)
                    HStack(alignment: .top) {
                        ClautoChoice(title: "Export resolution", selection: Binding(get: { project.manifest.outputResolution }, set: { value in
                            let captured = project; Task { await store.exportResolution(value, project: captured) }
                        }), options: ExportResolution.allCases.map { ($0, $0.label) })
                            .disabled(store.working || store.runningProjectID == project.id).accessibilityIdentifier("projectExportResolution")
                        ClautoChoice(title: "Picture shape", selection: Binding(get: { store.selected?.manifest.aspect ?? "16:9" }, set: { value in Task { await store.preferences(aspect: value) } }), options: [("16:9", "16:9 · landscape"), ("9:16", "9:16 · vertical")]).disabled(store.working)
                    }
                    ClautoChoice(title: "Local speech model", selection: Binding(get: { store.selected?.manifest.whisperModel ?? "large-v3" }, set: { value in Task { await store.preferences(model: value) } }), options: [("small", "Fast · small"), ("medium", "Balanced · medium"), ("large-v3", "Best · large-v3")]).disabled(store.working)
                    if project.manifest.outputResolution == .ultraHD { Text("4K may enlarge smaller footage without adding detail. Review the resulting picture.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
                }
                ClautoRule()
                ClautoSection("Sound & graphics", detail: "Use your recordings and licensed files. Missing pieces appear on the build sheet.") {
                    ClautoField(label: "Music", text: $brief.music, placeholder: "A mood, recording, or music wish")
                    ClautoField(label: "Graphics", text: $brief.graphics, placeholder: "What belongs on screen?")
                }
                ClautoSection("Script", detail: "Review the wording and factual claims before using an annotated script.") {
                    ClautoTextArea(text: $brief.script, label: "Script").frame(height: 114)
                    ClautoAction("Use as approved script", icon: .check) {
                        let submitted = brief.script, captured = project
                        Task { await store.approveScript(submitted, project: captured) }
                    }.disabled(brief.script.isEmpty || store.runningProjectID != nil)
                }
                ClautoField(label: "Things to avoid", text: $brief.avoid, placeholder: "Anything this cut should leave out")
                Text("Your brief saves automatically. The video house style stays Sage & Oat, cut cardboard and marker on paper.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            }.padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
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
                ClautoField(label: "Minimum seconds", text: $minimum, placeholder: "Optional").accessibilityIdentifier("minimumDuration")
                ClautoField(label: "Maximum seconds", text: $maximum, placeholder: "Optional").accessibilityIdentifier("maximumDuration")
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
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            if let issue { Text(issue).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
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
    @State private var targetedGroup: FileGroup?
    @State private var targeted = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Drop footage, recordings, images or scripts").font(ClautoDesign.type(18, weight: .semibold))
                    Spacer()
                    ClautoAction("Add files", icon: .add, kind: .primary) { Task { await store.intake(await FileDialogs.files(), copy: copyMedia) } }
                        .disabled(store.working || store.runningProjectID == project.id).accessibilityIdentifier("addFiles")
                }
                ClautoToggle(title: "Copy media into this project", isOn: $copyMedia)
                Text("Media is referenced by default. Scripts and notes are copied so you can edit them; originals stay untouched.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                ClautoDisclosure("Asset library & local models") {
                    HStack {
                        Button("Use Asset Library…") { Task { if let folder = await FileDialogs.folder() { await store.useProjectFolder(folder, key: "assets") } } }
                        Button("Choose Model Cache…") { Task { if let folder = await FileDialogs.folder() { await store.useProjectFolder(folder, key: "model_cache") } } }
                    }.disabled(store.runningProjectID != nil)
                    Text("An asset library contains textures, fonts, cutouts and foley. Speech models run locally from the chosen cache; missing models stop the run.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                }
                if store.working { ClautoActivity(label: "Updating project files…") }
                ForEach(FileGroup.allCases) { group in
                    ClautoSection(group.rawValue) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Choose \(group.rawValue)…") {
                                Task { await store.intake(await FileDialogs.files(), group: group, copy: copyMedia) }
                            }.disabled(store.working || store.runningProjectID == project.id)
                                .accessibilityLabel("Choose files for \(group.rawValue.lowercased())")
                                .accessibilityIdentifier("chooseGroup\(group.rawValue)")
                            let files = project.manifest.files.filter { $0.displayedGroup == group }
                            if files.isEmpty { Text("Drop \(group.rawValue.lowercased()) here, or use Add Files.").foregroundStyle(ClautoDesign.quiet).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                            ForEach(files) { file in fileRow(file) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !store.working, store.runningProjectID != project.id else { return false }
                        Task { await store.intake(urls, group: group, copy: copyMedia) }; return true
                    } isTargeted: { active in targetedGroup = active ? group : nil }
                    .padding(12).background(targetedGroup == group ? ClautoDesign.soft : .clear)
                    .overlay(Rectangle().stroke(targetedGroup == group ? ClautoDesign.rail : ClautoDesign.rule, lineWidth: 1))
                    .accessibilityLabel("\(group.rawValue) drop zone")
                }
            }.padding(24)
        }
        .dropDestination(for: URL.self) { urls, _ in guard !store.working, store.runningProjectID != project.id else { return false }
            Task { await store.intake(urls, copy: copyMedia) }; return true
        } isTargeted: { targeted = $0 }
        .background(targeted ? ClautoDesign.soft : ClautoDesign.paper)
    }
    private func fileRow(_ file: ProjectFile) -> some View {
        let url = project.folder.appendingPathComponent(file.relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(ClautoDesign.type(14, weight: .semibold)).lineLimit(2)
                Text(exists ? (file.copied ? "Copied into project" : "Referenced in place") : "Missing file — reconnect its drive")
                    .font(ClautoDesign.caption).foregroundStyle(exists ? ClautoDesign.quiet : ClautoDesign.ember)
                Text(file.originalPath).font(ClautoDesign.type(11)).foregroundStyle(ClautoDesign.quiet).lineLimit(1).clautoHelp(file.originalPath)
            }
            Spacer()
            if file.group == .audio || file.group == .music {
                ClautoChoice(title: file.needsRole ? "Choose a role" : "Role", selection: Binding(get: { file.group }, set: { role in Task { await store.assign(role, file: file) } }), options: [(FileGroup.music, "Music"), (.audio, "Recorded audio")]).frame(width: 145).disabled(store.working)
            }
            ClautoAction("Reveal", icon: .folder, kind: .quiet) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.originalPath)]) }.disabled(!exists)
                .accessibilityLabel("Reveal \(file.name) in Finder")
            ClautoAction("Remove", icon: .close, kind: .quiet) { Task { await store.remove(file) } }.disabled(store.working || store.runningProjectID == project.id)
                .accessibilityLabel("Remove \(file.name) from project")
        }
    }
}

struct CutView: View {
    @Bindable var store: EditorStore
    let playbackRouter: ReviewWindowRouter
    var showPlayers = true
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
                    if let current = store.currentCuts[project.id] {
                        ClautoRule(); Text("Current cut: v\(current.number) · \(current.label)").font(ClautoDesign.type(18, weight: .semibold))
                        if current.briefChanged(project) && project.manifest.importedReviewOnly != true {
                            Text("The brief changed since this cut. Run the updated inputs to make a new version.").foregroundStyle(ClautoDesign.ember)
                        }
                        if current.durationBounds != project.manifest.durationBounds {
                            Text("Duration limits changed since this cut. A new run uses the updated limits.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                        }
                        if let resolution = current.exportResolution {
                            Text("Saved output: \(resolution.label) · \(current.aspect ?? "16:9")").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                            if resolution != project.manifest.outputResolution || current.aspect != project.manifest.aspect {
                                Text("Output settings changed since this cut. A new run uses the updated settings.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                            }
                        }
                        versionResults(current, project: project)
                    }
                    Text(store.currentCuts[project.id] == nil ? "Make a first cut" : "Make another version").font(ClautoDesign.heading).accessibilityAddTraits(.isHeader)
                    Text("The engine transcribes and cuts locally, then pauses for your graphic-plan review. Original media stays untouched.").foregroundStyle(ClautoDesign.quiet)
                    ClautoField(label: "Version name", text: $versionLabel, placeholder: "First cut").accessibilityIdentifier("versionLabel")
                    ClautoChoice(title: "Narration clip", selection: $primaryID, options: [(Optional<UUID>.none, "Choose a clip")] + project.manifest.files.filter { $0.group == .footage }.map { (Optional($0.id), $0.name) }).accessibilityIdentifier("narrationClip")
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
                        .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    HStack {
                        Button("Check Project") { Task { await store.checkProject() } }.disabled(store.checking || store.runningProjectID != nil)
                        Button("Run Current Inputs") { Task { await store.beginCut(label: versionLabel, primaryID: primaryID, narrationIDs: narrationIDs) } }
                            .buttonStyle(ClautoButtonStyle(kind: .primary)).disabled(store.checking || store.runningProjectID != nil)
                            .accessibilityIdentifier("runInputs")
                        if store.runningProjectID == project.id { ClautoActivity(label: "Editing locally…"); Button("Stop") { Task { await store.cancel() } } }
                    }
                    if let summary = store.checkSummary { Text(summary).textSelection(.enabled) }
                    if let run {
                        Text("Run: \(run.state.rawValue)").bold()
                        if let failure = run.failure { Text(failure).foregroundStyle(ClautoDesign.ember).fixedSize(horizontal: false, vertical: true) }
                        ForEach(Array(1...5), id: \.self) { stage in
                            let event = run.events.last { $0.stage == stage }
                            HStack {
                                ClautoIcon(event?.state == "done" ? .check : .cut, size: 18)
                                Text(["Transcribe", "Rough cut", "Plan", "Assets", "Render"][stage - 1])
                                Spacer(); Text(event?.state ?? "Not run").foregroundStyle(ClautoDesign.quiet)
                            }
                        }
                        if run.state == .needsReview {
                            Text("Needs your review").font(ClautoDesign.type(18, weight: .semibold))
                            Text("Review every graphic, scientific claim, number and timing below. Approval applies only to this saved plan; editing it requires another review.")
                            Text(store.planReviews[project.id] ?? "Plan unavailable").font(ClautoDesign.type(12).monospacedDigit()).textSelection(.enabled)
                            Button("Approve Plan & Continue") { Task { await store.continueCut(approve: true) } }.disabled(store.runningProjectID != nil)
                        }
                        ForEach(store.missingPieces[project.id] ?? []) { piece in
                            ClautoSection(piece.ref) {
                                VStack(alignment: .leading) {
                                    Text(piece.status == "warn" ? "Needs attention" : "Missing").bold()
                                    Text(piece.notes.joined(separator: "\n"))
                                    Button("Choose Files…") { Task { await store.satisfy(piece, urls: await FileDialogs.files()) } }
                                        .accessibilityLabel("Choose files for missing \(piece.ref)")
                                }
                            }.dropDestination(for: URL.self) { urls, _ in Task { await store.satisfy(piece, urls: urls) }; return true }
                        }
                        if run.state == .needsAssets {
                            Text("Drops are checked by the engine for resolution, alpha and variants before the render can continue.").font(ClautoDesign.caption)
                            Button("Check Missing Pieces & Resume") { Task { await store.continueCut(approve: false) } }.disabled(store.runningProjectID != nil)
                        }
                        if run.state == .failed, run.approvedPlanHash != nil {
                            Button("Retry Assets & Render") { Task { await store.continueCut(approve: false) } }.disabled(store.runningProjectID != nil)
                        }
                    }
                    if !versions.isEmpty {
                        ClautoRule(); Text("Versions").font(ClautoDesign.type(18, weight: .semibold))
                        ForEach(versions) { version in
                            HStack {
                                Text("v\(version.number) · \(version.label)"); Spacer()
                                Button("Compare") { comparison = version.id }
                                Button("Restore") { Task { await store.restoreCut(version) } }.disabled(store.runningProjectID != nil)
                            }
                        }
                        if let compare = versions.first(where: { $0.id == comparison }) {
                            ClautoSection("Compare v\(compare.number)") { versionResults(compare, project: project) }
                        }
                    }
                    ClautoDisclosure("Details") { Text(store.details.isEmpty ? "No run output yet." : store.details).font(ClautoDesign.type(12).monospacedDigit()).textSelection(.enabled) }
                }.padding(24)
            }
        }
    }
    private func versionResults(_ version: CutVersion, project: Project) -> some View {
        let folder = project.folder.appendingPathComponent("cuts/" + version.folderName)
        return VStack(alignment: .leading, spacing: 12) {
            if project.manifest.importedReviewOnly == true {
                Text("Imported verified movie · review candidates use the watched movie. Original camera and graphics timeline is retained separately; new production approval is required for a production cut.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            }
            if showPlayers, let preview = version.preferredArtifact(".preview.mp4") ?? version.preferredArtifact(".mp4") {
                VersionReview(store: store, project: project, playbackRouter: playbackRouter, version: version, url: folder.appendingPathComponent(preview)).id(version.id)
            }
            DerivativeView(store: store, project: project, version: version).id(version.id)
            Text(version.savedSchemaChecked == true ? "The saved timeline passed Final Cut's schema check. Review the import before editing." : "Final Cut's schema check is unverified for this saved cut. Review the timeline import before editing.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            ForEach(version.artifacts.filter { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }, id: \.self) { artifact in
                Button("Open Timeline in Final Cut") { NSWorkspace.shared.open(folder.appendingPathComponent(artifact)) }
            }
            Button("Reveal Version") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Button("Export Script & Shot List PDF") {
                Task { if let url = await store.exportHandoff(version) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }.disabled(store.exportingPDF || project.manifest.importedReviewOnly == true)
            ForEach([version.preferredArtifact(".heard.txt"), version.preferredArtifact(".edl.json")].compactMap { $0 }, id: \.self) { artifact in
                ClautoDisclosure(artifact.hasSuffix(".heard.txt") ? "Rendered audio read-back" : "Cut points and reasons") {
                    Text((try? String(contentsOf: folder.appendingPathComponent(artifact), encoding: .utf8)) ?? "File unavailable").font(ClautoDesign.caption).textSelection(.enabled)
                }
            }
        }
    }
}

@MainActor
struct CutPreview: NSViewRepresentable {
    let url: URL
    @Binding var playhead: Double
    @Binding var playing: Bool
    @Binding var ready: Bool
    @Binding var failure: String?
    var control: ReviewPlaybackControl
    var onSeekRequested: () -> Void = {}
    var onSeekCompleted: (Bool) -> Void
    var onTimeJump: () -> Void
    var onSelect: (() -> Void)? = nil
    var validateOpening: (() throws -> Void)? = nil
    @MainActor final class Coordinator {
        var owner: CutPreview
        var player: AVPlayer?
        var observer: Any?
        var playbackObserver: NSKeyValueObservation?
        var itemObserver: NSKeyValueObservation?
        var generation = UUID()
        var jumpObserver: NSObjectProtocol?
        var requestedURL: URL?
        init(_ owner: CutPreview) { self.owner = owner }
        func install(_ player: AVPlayer) {
            teardown(); self.player = player
            owner.control.player = player
            let token = generation
            jumpObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: player.currentItem, queue: .main) { [weak self] _ in
                let coordinator = self
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == token else { return }
                    coordinator.owner.onTimeJump()
                }
            }
            playbackObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let active = player.timeControlStatus != .paused
                let coordinator = self
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == token else { return }
                    coordinator.owner.playing = active && coordinator.owner.ready && coordinator.owner.failure == nil
                }
            }
            itemObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                let coordinator = self
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == token else { return }
                    coordinator.owner.ready = status == .readyToPlay
                    if status == .failed {
                        coordinator.player?.pause(); coordinator.owner.playing = false
                        coordinator.owner.failure = "The saved preview is unavailable. Reconnect its drive or reveal this version to check its file."
                    }
                }
            }
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
            if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }; jumpObserver = nil
            owner.control.detach(player)
            if let observer { player?.removeTimeObserver(observer) }
            generation = UUID(); observer = nil; playbackObserver = nil; itemObserver = nil; player?.pause(); player = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    private func makePlayer() -> AVPlayer {
        do { try validateOpening?(); return AVPlayer(url: url) }
        catch {
            let message = error.localizedDescription
            Task { @MainActor in failure = message; ready = false }
            return AVPlayer()
        }
    }
    func makeNSView(context: Context) -> ClautoVideoCanvas {
        let view = ClautoVideoCanvas(frame: .zero)
        let player = makePlayer(); view.player = player; context.coordinator.install(player); context.coordinator.requestedURL = url
        return view
    }
    func updateNSView(_ view: ClautoVideoCanvas, context: Context) {
        context.coordinator.owner = self
        if context.coordinator.requestedURL != url {
            view.player?.pause()
            let player = makePlayer(); view.player = player; context.coordinator.install(player); context.coordinator.requestedURL = url
        }
        view.onSelect = onSelect
        view.onSpace = { [weak control] in onSelect?(); control?.toggle() }
        control.onSeekRequested = onSeekRequested
        control.onSeekCompleted = onSeekCompleted
    }

    static func dismantleNSView(_ view: ClautoVideoCanvas, coordinator: Coordinator) {
        coordinator.teardown()
        view.player?.pause()
        view.player = nil
    }
}


struct VersionReview: View {
    @Bindable var store: EditorStore
    var project: Project
    let playbackRouter: ReviewWindowRouter
    var version: CutVersion
    var url: URL
    @State private var playhead = 0.0
    @State private var endpoint: ReviewPlaybackEndpoint?
    @State private var control = ReviewPlaybackControl()
    @State private var start = "0"
    @State private var end = ""
    @State private var text = ""
    @State private var saving = false
    @State private var playing = false
    @State private var duration = 0.0
    @State private var loading = true
    @State private var ready = false
    @State private var playbackIssue: String?
    @State private var voiceToken = UUID()
    private var voice: VoiceReviewController? { store.voiceReviews[project.id] }
    private func livePlayhead() -> VoiceLivePlayhead {
        guard let player = control.player else { return .init(host: VoiceLivePlayhead.now, seconds: 0, rate: 0, available: false) }
        let time = player.currentTime().seconds
        return .init(host: VoiceLivePlayhead.now, seconds: time.isFinite && time >= 0 ? time : 0,
            rate: player.timeControlStatus == .playing ? Double(player.rate) : 0,
            available: ready && !control.seeking && playbackIssue == nil && time.isFinite && time >= 0 && time <= duration)
    }
    private func selectForVoiceReview() {
        guard let controller = store.voiceReview(for: project) else { return }
        controller.willAttach(voiceToken)
        Task { await store.bindVoiceReview(version: version, project: project, token: voiceToken, sampler: livePlayhead) }
    }
    private func requestSeek(_ seconds: Double) { control.seek(seconds: seconds) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CutPreview(url: url, playhead: $playhead, playing: $playing, ready: $ready, failure: $playbackIssue, control: control,
                onSeekRequested: { voice?.record(livePlayhead(),kind: .seekRequested,token: voiceToken) },
                onSeekCompleted: { completed in
                    voice?.record(livePlayhead(), kind: completed ? .seekCompleted : .unavailable, token: voiceToken)
                }, onTimeJump: { voice?.record(livePlayhead(), kind: control.seeking ? .seekRequested : .unavailable, token: voiceToken) }, onSelect: { playbackRouter.select(voiceToken) })
                .aspectRatio(16/9, contentMode: .fit).frame(maxHeight: 410).background(ClautoDesign.ink)
                .overlay { if playbackIssue != nil { ClautoUnavailablePreview() } }
            if loading || (!ready && playbackIssue == nil) { ClautoActivity(label: "Loading the local cut…") }
            if let playbackIssue { Text(playbackIssue).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                ClautoAction(playing ? "Pause" : "Play", icon: playing ? .pause : .play, kind: .primary) {
                    control.toggle()
                }.disabled(duration <= 0 || !ready || control.seeking)
                ClautoSlider(value: Binding(get: { playhead }, set: { requestSeek($0) }), range: 0...max(1, duration), label: "Review playhead").disabled(duration <= 0 || !ready)
                Text(String(format: "%02d:%02d / %02d:%02d", Int(playhead)/60, Int(playhead)%60, Int(duration)/60, Int(duration)%60))
                    .font(ClautoDesign.caption.monospacedDigit()).foregroundStyle(ClautoDesign.quiet)
            }
            if let endpoint {
                HStack {
                    Button(playbackRouter.selectedID == endpoint.id ? "Shortcuts use this player" : "Use this player for shortcuts") { playbackRouter.select(endpoint.id) }
                        .disabled(playbackRouter.selectedID == endpoint.id).accessibilityIdentifier("selectPlaybackPlayer")
                    Button("Pause and Comment / Circle…") { playbackRouter.select(endpoint.id); playbackRouter.beginComment(endpoint) }
                        .disabled(!endpoint.ready || voice?.canPresentCandidate != true).accessibilityIdentifier("addFrameComment")
                }
                Text("⌘⌥P play/pause · ⌘⌥← / → skip · ⌃⌥⌘M pause and comment · Space when the video has focus")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                if let comments = store.frameComments[project.id] {
                    ForEach(comments.comments.filter { $0.request.target.versionID == version.id }) { comment in
                        HStack(alignment: .top) {
                            Button(String(format: "Frame %d · %.6fs", comment.request.frame.frameIndex,comment.request.frame.seconds)) { requestSeek(comment.request.frame.seconds) }
                            Text(comment.text).textSelection(.enabled)
                            Text("\(comment.annotations.count) marks").font(ClautoDesign.caption)
                            Spacer()
                            Button("Open / Revise") { playbackRouter.edit(comment,project: project) }
                        }
                    }
                    if let error = comments.error, comments.draft == nil { Text(error).foregroundStyle(ClautoDesign.ember) }
                }
            }
            if let voice { VoiceReviewView(controller: voice, versionID: version.id, engine: store.engineRoot, selected: voice.isAttached(to: voiceToken), select: selectForVoiceReview, seek: requestSeek, prepareCandidatePlayback: { token in
                guard voice.isAttached(to: voiceToken), voice.beginCandidatePlayback(token) else { return false }
                control.pause(); playing = false
                voice.record(livePlayhead(),kind: .pause,token: voiceToken)
                return true
            }) }
            ClautoSection("Feedback for v\(version.number)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Use Playhead") {
                            let time = control.player?.currentTime().seconds ?? playhead
                            if time.isFinite { start = String(format: "%.6f", max(0, time)) }
                        }
                            .disabled(!ready).accessibilityIdentifier("feedbackUsePlayhead")
                        ClautoField(label: "Start seconds", text: $start).frame(width: 110).accessibilityIdentifier("feedbackStart")
                        ClautoField(label: "End seconds", text: $end, placeholder: "Optional").frame(width: 160).accessibilityIdentifier("feedbackEnd")
                    }
                    ClautoField(label: "What should change at this moment?", text: $text).accessibilityIdentifier("feedbackText")
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
                            Button(entry.endSeconds.map { String(format: "%.3f–%.3fs", entry.startSeconds, $0) } ?? String(format: "%.3fs", entry.startSeconds)) { requestSeek(entry.startSeconds) }
                                .disabled(entry.attachment != .verified)
                                .accessibilityLabel("Go to feedback at \(entry.startSeconds) seconds")
                            VStack(alignment: .leading) {
                                Text(entry.text).textSelection(.enabled)
                                if let end = entry.endSeconds { Text(String(format: "Range %.3f–%.3f seconds", entry.startSeconds, end)).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
                                Text(entry.resolved ? "Resolved" : "Open").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                                if entry.attachment != .verified {
                                    Text("Saved version or time range changed. Restore the verified cut to use this feedback.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                                }
                            }
                            Spacer()
                            Button(entry.resolved ? "Reopen" : "Resolve") { Task { await store.resolveFeedback(entry.id, resolved: !entry.resolved, project: project) } }
                                .disabled(entry.attachment != .verified)
                        }
                    }
                    Text("Feedback stays attached to this saved version. The cut is unchanged until a reviewed edit applies it.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
        .task(id: url) {
            let controller = store.voiceReview(for: project)
            let wasSelected = controller?.isAttached(to: voiceToken) == true
            if wasSelected { controller?.willAttach(voiceToken) }
            await controller?.load()
            loading = true; playbackIssue = nil; duration = 0; playhead = 0; playing = false; ready = false
            do {
                let loaded = try await AVURLAsset(url: url).load(.duration)
                guard !Task.isCancelled else { return }
                if loaded.seconds.isFinite, loaded.seconds > 0 {
                    duration = loaded.seconds
                    ready = control.player?.currentItem?.status == .readyToPlay
                    if control.player?.currentItem?.status == .failed {
                        control.player?.pause(); playing = false
                        playbackIssue = "The saved preview is unavailable. Reconnect its drive or reveal this version to check its file."
                    }
                }
                else { playbackIssue = "The saved preview has no readable duration. Reveal this version to check its file." }
            } catch {
                guard !Task.isCancelled else { return }
                playbackIssue = "The saved preview is unavailable. Reconnect its drive or reveal this version to check its file."
            }
            loading = false
            guard !Task.isCancelled else { return }
            do {
                let target = try await store.playbackTarget(version: version,project: project)
                guard !Task.isCancelled else { return }
                let next = ReviewPlaybackEndpoint(id: voiceToken,project: project,target: target,driver: control)
                endpoint = next; playbackRouter.register(next)
                await store.frameComment(for: project).load()
            } catch { store.notice = error.localizedDescription }
            if wasSelected { await store.bindVoiceReview(version: version, project: project, token: voiceToken, sampler: livePlayhead) }
        }
        .task(id: voiceToken) {
            while !Task.isCancelled {
                voice?.record(livePlayhead(), token: voiceToken)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onChange(of: ready) {
            if ready { Task { await store.recordReviewLaunch(version: version,project: project,playerSeconds: control.player?.currentTime().seconds ?? 0) } }
        }
        .onChange(of: playing) { voice?.record(livePlayhead(), kind: playing ? .play : .pause, token: voiceToken) }
        .onDisappear { playbackRouter.unregister(voiceToken); voice?.detach(voiceToken) }
        .onChange(of: playhead) { if duration > 0 && playhead >= duration - 0.05 { playing = false } }
    }
}
