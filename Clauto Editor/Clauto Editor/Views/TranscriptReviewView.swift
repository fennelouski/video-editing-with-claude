import SwiftUI
import AppKit

struct TranscriptReviewView: View {
    @Bindable var store: EditorStore
    let project: Project
    @State private var controller: TranscriptReviewController?
    var body: some View {
        Group {
            if let controller { TranscriptWorkspace(controller: controller) }
            else { ClautoActivity(label: "Opening transcript review…").padding(28) }
        }
        .task(id: project.id) {
            let captured = store.transcriptReview(for: project)
            controller = captured
            if captured.session == nil { await captured.load() }
        }
    }
}

struct TranscriptWorkspace: View {
    @Bindable var controller: TranscriptReviewController
    @State private var query = ""
    @State private var scope = TranscriptScope.all
    @State private var selectedID: String?
    @State private var visibleRows: [TranscriptDisplayRow] = []
    @State private var compactInspectorOpen = false

    init(controller: TranscriptReviewController, initialSelectedID: String? = nil) {
        self.controller = controller
        // Explicit one-time selection seed for a newly opened review surface.
        _selectedID = State(initialValue: initialSelectedID)
        _compactInspectorOpen = State(initialValue: initialSelectedID != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            if let failure = controller.failure {
                VStack(alignment: .leading, spacing: 10) {
                    Text(failure).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                    HStack {
                        if controller.dirty {
                            Button("Retry save") { Task { await controller.flush() } }
                            Button("Save draft copy and reload") { Task { await controller.saveDraftAndReload() } }
                        } else { Button("Reload review") { Task { await controller.load() } } }
                    }.disabled(controller.loading || controller.saving)
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
            if controller.session != nil {
                filters.padding(.horizontal, 24).padding(.bottom, 16)
                ClautoRule()
                GeometryReader { geometry in
                    if geometry.size.width >= 920 {
                        HStack(spacing: 0) {
                            passages
                            Rectangle().fill(ClautoDesign.rule).frame(width: 1)
                            inspector.frame(width: 330).background(ClautoDesign.sheet)
                        }
                    } else {
                        if compactInspectorOpen, selectedID != nil {
                            VStack(spacing: 0) {
                                HStack {
                                    Button("Back to passages") { compactInspectorOpen = false }
                                    Spacer()
                                }.padding(.horizontal, 18).padding(.vertical, 10)
                                ClautoRule()
                                inspector.frame(maxHeight: .infinity).background(ClautoDesign.sheet)
                            }
                        } else {
                            VStack(spacing: 0) {
                                if selectedID != nil {
                                    Button("Show selected passage notes") { compactInspectorOpen = true }
                                        .padding(10)
                                }
                                passages
                            }
                        }
                    }
                }
            } else if controller.loading {
                ClautoActivity(label: "Checking the saved source rows…").padding(24)
                Spacer()
            } else {
                ClautoEmpty(title: "Start with the spoken words", detail: "Import a saved complete transcript catalog. Keep passages, build their order, and leave notes alongside the recorded speech.")
                    .padding(28)
                Spacer()
            }
        }
        .background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).font(ClautoDesign.body)
        .buttonStyle(ClautoButtonStyle()).scrollIndicators(.hidden)
        .disabled(controller.loading)
        .onChange(of: controller.session?.state.revisionID, initial: true) { refresh() }
        .onChange(of: controller.session?.state.rowOrder) { refresh() }
        .onChange(of: controller.generationForDisplay) { refresh() }
        .onChange(of: query) { refresh() }
        .onChange(of: scope) { refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Build the spoken story").font(ClautoDesign.type(20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if let session = controller.session {
                        Text("\(session.keptCount) kept of \(session.catalog.rows.count) passages · \(session.catalog.sources.count) source \(session.catalog.sources.count == 1 ? "clip" : "clips")")
                            .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                        Text(controller.failure != nil && controller.dirty ? "Review changes are not saved" : controller.dirty || controller.saving ? "Saving review choices…" : "Draft saved · checkpoint \(session.state.revisionNumber)")
                            .font(ClautoDesign.caption).foregroundStyle(controller.failure == nil ? ClautoDesign.quiet : ClautoDesign.ember)
                        if !session.selectedBoundsIssues.isEmpty {
                            Text("\(session.selectedBoundsIssues.count) kept passage(s) need source-boundary review.")
                                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    if let session = controller.session {
                        ClautoAction("Export review selections", icon: .export, kind: .primary) { Task { await controller.exportSelections() } }
                            .accessibilityIdentifier("exportTranscriptSelections")
                        Button("Undo last saved change") { Task { await controller.undo() } }
                            .disabled(session.state.undoTargetRevisionID == nil || controller.saving)
                            .accessibilityIdentifier("undoTranscriptChange")
                    } else {
                        ClautoAction("Import transcript", icon: .add, kind: .primary) {
                            Task { if let url = await FileDialogs.transcript() { await controller.importCatalog(url) } }
                        }.accessibilityIdentifier("importTranscriptCatalog")
                    }
                }
            }
            Text("Choices save with this project. Exporting prepares a review package; it does not approve speech or change a cut.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet).fixedSize(horizontal: false, vertical: true)
            if controller.loading { ClautoActivity(label: controller.operationDescription) }
            if let url = controller.exportedURL {
                Button("Reveal exported selections") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if let url = controller.recoveredDraftURL {
                Button("Reveal preserved pending draft") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 14) {
                search
                scopeChoice.frame(width: 170)
            }
            VStack(alignment: .leading, spacing: 12) { search; scopeChoice }
        }
    }
    private var search: some View { ClautoField(label: "Find speech, clip or stable ID", text: $query).accessibilityIdentifier("transcriptSearch") }
    private var scopeChoice: some View {
        ClautoChoice(title: "Show", selection: $scope, options: TranscriptScope.allCases.map { ($0, $0.rawValue) })
            .accessibilityIdentifier("transcriptScope")
    }

    private var passages: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleRows) { entry in
                    TranscriptPassageRow(entry: entry, selected: entry.id == selectedID,
                        keep: Binding(get: { controller.session?.state.decisions[entry.id]?.keep ?? false },
                                      set: { value in controller.change(entry.id) { $0.keep = value } }),
                        select: { selectedID = entry.id; compactInspectorOpen = true })
                }
                if visibleRows.isEmpty {
                    Text("No passages match. Change the search or Show choice.")
                        .font(ClautoDesign.body).foregroundStyle(ClautoDesign.quiet).padding(28)
                }
            }
        }.accessibilityIdentifier("transcriptPassages")
    }

    @ViewBuilder private var inspector: some View {
        if let session = controller.session, let id = selectedID,
           let row = session.rowsByID[id], let index = session.state.rowOrder.firstIndex(of: id) {
            TranscriptPassageInspector(controller: controller, row: row, position: index + 1,
                reorderEnabled: scope == .all && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .id(id)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Passage notes").font(ClautoDesign.type(18, weight: .semibold))
                Text("Choose a passage to see its source identity and leave comments or graphic requests.")
                    .font(ClautoDesign.body).foregroundStyle(ClautoDesign.quiet)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func refresh() {
        guard let session = controller.session else { visibleRows = []; return }
        visibleRows = TranscriptDisplayRow.make(session: session, query: query, scope: scope)
        // Filtering/reordering retains the selected source ID, even when hidden.
        if let selectedID, session.state.decisions[selectedID] == nil { self.selectedID = nil }
    }
}

private struct TranscriptPassageRow: View {
    let entry: TranscriptDisplayRow
    let selected: Bool
    @Binding var keep: Bool
    let select: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClautoToggle(title: "Keep", isOn: $keep)
                .accessibilityLabel("Keep passage from \(entry.row.sourceID) at \(entry.row.inTimecode)")
                .accessibilityIdentifier("transcriptKeep-" + entry.id)
            Button(action: select) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(entry.position). \(entry.row.sourceID) · \(entry.row.inTimecode)–\(entry.row.outTimecode)")
                        .font(ClautoDesign.caption.monospacedDigit()).foregroundStyle(ClautoDesign.quiet)
                    Text(entry.row.text).font(ClautoDesign.body).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                    if !entry.row.uncertainty.isEmpty {
                        Text("Transcript review note").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                    }
                    if !entry.decision.comment.isEmpty || !entry.decision.graphicRequest.isEmpty {
                        Text("Has review notes").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    }
                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(ClautoInlineButtonStyle(selected: selected))
                .accessibilityLabel("Review passage \(entry.position), \(entry.row.sourceID), \(entry.row.text)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("transcriptPassage-" + entry.id)
        }.padding(18).background(selected ? ClautoDesign.soft : ClautoDesign.paper)
            .overlay(alignment: .bottom) { ClautoRule() }
    }
}

private struct TranscriptPassageInspector: View {
    @Bindable var controller: TranscriptReviewController
    let row: TranscriptRow
    let position: Int
    let reorderEnabled: Bool
    @State private var positionText: String
    init(controller: TranscriptReviewController, row: TranscriptRow, position: Int, reorderEnabled: Bool) {
        self.controller = controller; self.row = row; self.position = position; self.reorderEnabled = reorderEnabled
        // One-time seed; parent keys this inspector by immutable row ID.
        _positionText = State(initialValue: String(position))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ClautoSection("Source passage") {
                    Text(row.sourceID).font(ClautoDesign.type(15, weight: .semibold)).textSelection(.enabled)
                    Text("\(row.inTimecode)–\(row.outTimecode)").font(ClautoDesign.caption.monospacedDigit()).textSelection(.enabled)
                    Text(String(format: "Original source: %.3f–%.3f seconds", row.start, row.end)).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    Text(row.section).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    Text(row.text).font(ClautoDesign.body).textSelection(.enabled)
                    if !row.uncertainty.isEmpty { Text(row.uncertainty).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
                }
                ClautoSection("Story order") {
                    HStack {
                        Button("Earlier") { controller.move(row.id, to: position - 1) }
                            .disabled(!reorderEnabled || position <= 1).keyboardShortcut(.upArrow, modifiers: [.command, .option])
                        Button("Later") { controller.move(row.id, to: position + 1) }
                            .disabled(!reorderEnabled || position >= (controller.session?.state.rowOrder.count ?? 0))
                            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    }
                    HStack(alignment: .bottom) {
                        ClautoField(label: "Story position", text: $positionText)
                        Button("Move") {
                            if let target = Int(positionText) { controller.move(row.id, to: target) }
                            else { controller.failure = "Enter a whole-number story position." }
                        }.disabled(!reorderEnabled)
                    }
                    if !reorderEnabled { Text("Show all passages and clear search to reorder the full story.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
                }
                ClautoRule()
                ClautoSection("Comment", detail: "Wording changes and editorial notes stay separate from the recorded words.") {
                    ClautoTextArea(text: annotation(\.comment), label: "Passage comment").frame(height: 90).accessibilityIdentifier("transcriptComment")
                }
                ClautoSection("Requested graphics") {
                    ClautoTextArea(text: annotation(\.graphicRequest), label: "Requested graphics").frame(height: 90).accessibilityIdentifier("transcriptGraphicRequest")
                    ClautoField(label: "Handwritten asset reference", text: annotation(\.handwritingReference)).accessibilityIdentifier("transcriptHandwritingReference")
                }
                if !row.assistantGraphics.isEmpty {
                    ClautoSection("Imported graphic suggestion", detail: "A proposal for consideration; it is not a requested or approved graphic.") {
                        Text(row.assistantGraphics).font(ClautoDesign.body).textSelection(.enabled)
                    }
                }
                ClautoDisclosure("Stable source identity") {
                    Text(row.id).font(ClautoDesign.caption).textSelection(.enabled)
                    Text("Source SHA-256: " + row.sourceSHA256).font(ClautoDesign.caption).textSelection(.enabled)
                    Text("Original word indices \(row.firstWord)–\(row.lastWord), inclusive.").font(ClautoDesign.caption)
                }
            }.padding(24)
        }.onChange(of: position) { positionText = String(position) }
    }
    private func annotation(_ field: WritableKeyPath<TranscriptRowDecision, String>) -> Binding<String> {
        Binding(get: { controller.session?.state.decisions[row.id].map { $0[keyPath: field] } ?? "" },
                set: { value in controller.change(row.id) { $0[keyPath: field] = value } })
    }
}
