import SwiftUI
import AppKit

struct ScriptWorkspaceView: View {
    @Bindable var store: EditorStore
    let project: Project
    let router: ReviewWindowRouter
    var body: some View {
        let controller = store.scriptWorkspace(for: project)
        ScriptWorkspaceContent(controller: controller, openTranscript: { router.tab = "Transcript" }, openCut: {
            controller.requestedAssemblyID = controller.assemblies.last?.id; router.tab = "Cut"
        }).task { await controller.load() }
    }
}

private struct ScriptWorkspaceContent: View {
    @Bindable var controller: ScriptWorkspaceController
    let openTranscript: () -> Void
    let openCut: () -> Void
    @State private var page = "Sources"
    @State private var selectedVersion: UUID?
    @State private var query = ""
    @State private var newVersion = false
    @State private var addingPassage = false
    @State private var addingPickup = false
    @State private var editedBeat: ScriptBeat?
    @State private var factsReviewed = false
    @State private var pickedVersions: Set<UUID> = []
    @State private var renamingVersion = false
    private var session: ScriptWorkspaceSession? { controller.session }
    private var version: ScriptVersion? { session?.state.versions.first(where: { $0.id == selectedVersion }) }
    private var mustCompare: Bool { session?.state.reviewInProgress == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(22)
            if let error = controller.failure {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(ClautoDesign.ember).textSelection(.enabled)
                    Spacer(); Button("Reload saved workspace") { Task { await controller.load() } }
                }.font(ClautoDesign.caption).padding(.horizontal, 22).padding(.bottom, 12).accessibilityIdentifier("scriptFailure")
            }
            if let error = controller.assemblyFailure {
                Text(error).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).padding(.horizontal, 22).padding(.bottom, 12)
            }
            if controller.busy { ClautoActivity(label: "Checking and saving script work…").padding(.horizontal, 22).padding(.bottom, 12) }
            if let url = controller.exportedURL {
                HStack {
                    Text("Project package saved").font(ClautoDesign.caption)
                    if !controller.assemblies.isEmpty { Button("Review assembly in Cut") { openCut() }.accessibilityIdentifier("reviewScriptAssemblyInCut") }
                    Button("Show package in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.padding(.horizontal, 22).padding(.bottom, 12).accessibilityIdentifier("scriptPackageSaved")
            }
            ClautoRule()
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if mustCompare || page == "Compare" { comparison(session) }
                        else if page == "Sources" { sourceReview(session) }
                        else { writing(session) }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.visible)
            } else if !controller.busy {
                VStack(alignment: .leading, spacing: 14) {
                    ClautoEmpty(title: "Read the sources first", detail: "Import a complete transcript catalog in Transcript, then return here to review all passages before drafting independent script versions.")
                    Button("Open this project's Transcript workspace") { openTranscript() }.accessibilityIdentifier("scriptOpenTranscript")
                }.padding(28)
            }
        }.font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).background(ClautoDesign.paper)
            .buttonStyle(ClautoButtonStyle())
            .disabled(controller.busy)
            .onChange(of: session?.state.revisionID) {
                factsReviewed = false
                if selectedVersion == nil { selectedVersion = session?.state.versions.first?.id }
            }
            .onAppear {
                if let id = controller.requestedVersionID { selectedVersion = id; page = "Write"; controller.requestedVersionID = nil }
            }
            .sheet(isPresented: $newVersion) {
                ScriptNewVersionSheet(failure: controller.failure) { title, provenance, data in
                    let action: ScriptWorkspaceAction = data.map { .importScript($0, provenance, title) } ?? .create(title, provenance)
                    if await controller.perform(action) { selectedVersion = controller.session?.state.versions.last?.id; page = "Write"; newVersion = false }
                }
            }
            .sheet(isPresented: $addingPassage) {
                if let session, let version {
                    ScriptPassagePicker(catalog: session.catalog, selected: Set(version.beats.compactMap(\.rowID))) { rowID in
                        if await controller.perform(.addPassage(version.id, rowID)) { addingPassage = false }
                    }
                }
            }
            .sheet(isPresented: $addingPickup) {
                ScriptBeatSheet(beat: .init(kind: .pickup, heading: "Pickup", unrecordedText: ""), isNew: true, failure: controller.failure) { beat in
                    if let version, await controller.perform(.addPickup(version.id, beat.unrecordedText)) { addingPickup = false }
                }
            }
            .sheet(item: $editedBeat) { beat in
                ScriptBeatSheet(beat: beat, isNew: false, failure: controller.failure) { saved in
                    if let version, await controller.perform(.editBeat(version.id, saved.id, saved.heading, saved.notes, saved.unrecordedText)) { editedBeat = nil }
                }
            }
            .sheet(isPresented: $renamingVersion) {
                if let version {
                    ScriptRenameSheet(title: version.title) { title in
                        if await controller.perform(.rename(version.id, title)) { renamingVersion = false }
                    }
                }
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Script first").font(ClautoDesign.type(21, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("Read every source → write independent versions → compare blind → approve → prepare a separate assembly.")
                .font(ClautoDesign.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                ClautoSegments(selection: $page, options: [("Sources", .files), ("Write", .brief), ("Compare", .cut)])
                    .disabled(mustCompare).accessibilityIdentifier("scriptWorkspacePages")
                Spacer()
                if !mustCompare {
                    if !controller.assemblies.isEmpty { Button("Assemblies in Cut") { openCut() } }
                    Button("New / import version") { newVersion = true }.disabled(session?.coverageComplete != true).accessibilityIdentifier("newScriptVersion")
                }
            }
            if let session {
                Text("\(session.state.reviewedRowIDs.count) of \(session.catalog.rows.count) source passages reviewed · \(session.state.versions.count) script versions · \(session.coverageComplete ? "Source review complete" : "Source review required")")
                    .font(ClautoDesign.caption).accessibilityIdentifier("scriptCoverageStatus")
            }
        }
    }

    @ViewBuilder private func sourceReview(_ session: ScriptWorkspaceSession) -> some View {
        Text("Full source transcript").font(ClautoDesign.type(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
        Text("Review all recorded speech, including excluded takes. These acknowledgments record your review of the supplied ASR; listening and transcript accuracy need human judgment.").font(ClautoDesign.caption)
        ClautoField(label: "Find a source passage", text: $query, placeholder: "Words, clip or timecode")
        if !session.missingSources.isEmpty {
            Text("Media absent from this speech catalog").accessibilityAddTraits(.isHeader)
            Text("Import speech transcripts before drafting. For reviewed B-roll or an item with no relevant speech, record an explicit reason below; silence is never inferred.").font(ClautoDesign.caption)
            ForEach(session.missingSources) { file in
                ScriptDispositionRow(file: file, current: session.state.nonTranscriptDispositions[file.id] ?? "") { note in
                    await controller.perform(.disposition(file.id, note))
                }
            }
        }
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(session.catalog.rows.sorted { $0.originalOrder < $1.originalOrder }.filter { query.isEmpty || [$0.text, $0.sourceID, $0.inTimecode].contains(where: { $0.localizedStandardContains(query) }) }) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text("\(row.sourceID) · \(row.inTimecode)–\(row.outTimecode)").font(ClautoDesign.caption).textSelection(.enabled)
                        Spacer()
                        Button(session.state.reviewedRowIDs.contains(row.id) ? "Reviewed · undo" : "Mark reviewed") {
                            Task { await controller.perform(.reviewed(row.id, !session.state.reviewedRowIDs.contains(row.id))) }
                        }.accessibilityLabel("\(session.state.reviewedRowIDs.contains(row.id) ? "Undo review of" : "Mark reviewed") passage \(row.originalOrder), \(row.sourceID)")
                            .accessibilityIdentifier("scriptReview-\(row.id)")
                    }
                    Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !row.uncertainty.isEmpty { Text(row.uncertainty).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
                    ClautoDisclosure("Source trace") {
                        Text("\(row.id)\nSource SHA-256: \(row.sourceSHA256)\nWord indexes: \(row.firstWord)…\(row.lastWord)\nSource seconds: \(row.start)–\(row.end)").font(ClautoDesign.caption).textSelection(.enabled)
                    }
                }.padding(14).background(ClautoDesign.sheet).accessibilityElement(children: .contain)
            }
        }
        Button("Export local writer packet") { Task { await controller.exportWriterPacket() } }.disabled(!session.coverageComplete).accessibilityIdentifier("exportScriptWriterPacket")
        Text("The packet stays local. Import a real writer's source-bound JSON as another version; no AI service is called or credited with a draft here.").font(ClautoDesign.caption)
    }

    @ViewBuilder private func writing(_ session: ScriptWorkspaceSession) -> some View {
        if session.state.versions.isEmpty {
            ClautoEmpty(title: "Give the story its own draft", detail: "After source review, create an empty script or import a source-bound writer response. Each version keeps its own beat order and pickups.")
        } else {
            ClautoChoice(title: "Script version", selection: $selectedVersion, options: session.state.versions.map { (Optional($0.id), $0.title) })
            if let version {
                HStack {
                    Button("Rename") { renamingVersion = true }
                    Button("Duplicate as a new version") { Task { if await controller.perform(.duplicate(version.id, version.title + " — alternative")) { selectedVersion = controller.session?.state.versions.last?.id } } }
                    Spacer()
                    Text(session.state.approvalCurrent(version) ? "Approved script" : "Draft · approval required").font(ClautoDesign.caption).accessibilityIdentifier("scriptApprovalStatus")
                }
                Text("Private provenance: \(version.provenance.author)\(version.provenance.model.isEmpty ? "" : " · " + version.provenance.model) · \(version.provenance.origin). Identity unverified.").font(ClautoDesign.caption).textSelection(.enabled)
                HStack {
                    Button("Add recorded passage") { addingPassage = true }.disabled(!session.coverageComplete).accessibilityIdentifier("scriptAddPassage")
                    Button("Add unrecorded pickup") { addingPickup = true }.accessibilityIdentifier("scriptAddPickup")
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(version.beats) { beat in
                        ScriptBeatRow(beat: beat, position: (version.beats.firstIndex(where: { $0.id == beat.id }) ?? 0) + 1,
                            row: session.catalog.rows.first(where: { $0.id == beat.rowID }),
                            first: version.beats.first?.id == beat.id, last: version.beats.last?.id == beat.id,
                            edit: { editedBeat = beat }, move: { delta in Task { await controller.perform(.move(version.id, beat.id, delta)) } },
                            remove: { Task { await controller.perform(.remove(version.id, beat.id)) } })
                    }
                }
                ClautoRule()
                ClautoToggle(title: "I reviewed this script's factual claims, numbers, wording and source choices", isOn: $factsReviewed)
                HStack {
                    Button("Approve this script") { Task { await controller.perform(.approve(version.id, factsReviewed)) } }.disabled(!factsReviewed || !session.coverageComplete).accessibilityIdentifier("approveScriptVersion")
                    Button("Prepare timeline candidate") { Task { await controller.assemble(version.id) } }
                        .disabled(!session.state.approvalCurrent(version) || version.beats.contains(where: { $0.kind == .pickup })).accessibilityIdentifier("assembleScriptCandidate")
                }
                Text(version.beats.contains(where: { $0.kind == .pickup }) ? "Unrecorded pickups block assembly. Record/transcribe them or remove them, then approve the changed script." : "Assembly verifies source bytes and adds a source-linked candidate to this project's Cut workspace. Edits require review again. The current cut stays unchanged; preview rendering and production approval remain separate.").font(ClautoDesign.caption)
            }
        }
    }

    @ViewBuilder private func comparison(_ session: ScriptWorkspaceSession) -> some View {
        Text("Author-blind comparison").font(ClautoDesign.type(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
        if let comparison = session.state.comparison, session.state.comparisonCurrent(), let options = try? session.state.blindOptions(catalog: session.catalog) {
            Text(comparison.lockedAt == nil ? "Author, model, version title and import metadata are hidden. Score every option from 1 to 5 before locking. Editing is paused during review." : "Scores locked. Author details can now be revealed.").font(ClautoDesign.caption)
            Text("Script wording can itself suggest authorship. This mode masks metadata; it does not establish formal blinding.").font(ClautoDesign.caption)
            ForEach(options) { option in
                ScriptBlindCard(option: option, locked: comparison.lockedAt != nil) { score in Task { await controller.perform(.score(option.id, score)) } }
            }
            if comparison.lockedAt == nil {
                HStack {
                    Button("Lock all scores") { Task { await controller.perform(.lockScores) } }.disabled(!options.allSatisfy { $0.score.complete }).accessibilityIdentifier("lockScriptScores")
                    Button("Cancel comparison") { Task { await controller.perform(.cancelComparison) } }
                }
            } else {
                Button("Reveal author and model details") { Task { await controller.perform(.reveal) } }.disabled(comparison.authorsRevealed).accessibilityIdentifier("revealScriptAuthors")
                if comparison.authorsRevealed {
                    ForEach(comparison.entries) { entry in
                        if let version = session.state.versions.first(where: { $0.id == entry.versionID }) {
                            Text("\(entry.label): \(version.title) · \(version.provenance.author) · \(version.provenance.model) · \(version.provenance.origin)").font(ClautoDesign.caption).textSelection(.enabled)
                        }
                    }
                }
                Button("Start another comparison") { Task { await controller.perform(.cancelComparison) } }
            }
        } else {
            Text("Choose versions, then start review. Their order is randomized once and saved; author details stay out of the scoring surface.").font(ClautoDesign.caption)
            if session.state.comparison != nil { Text("Scripts or coverage changed. Earlier scores remain in saved checkpoints; compare the current versions again.").foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption) }
            ForEach(session.state.versions) { version in
                ClautoToggle(title: version.title, isOn: Binding(get: { pickedVersions.contains(version.id) }, set: { selected in if selected { pickedVersions.insert(version.id) } else { pickedVersions.remove(version.id) } }))
            }
            Button("Begin blind comparison") { Task { await controller.perform(.compare(session.state.versions.filter { pickedVersions.contains($0.id) }.map(\.id))) } }
                .disabled(pickedVersions.count < 2 || !session.coverageComplete).accessibilityIdentifier("beginBlindScriptComparison")
        }
    }
}
