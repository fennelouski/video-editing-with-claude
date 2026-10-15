import SwiftUI
import AVFoundation

struct VoiceReviewView: View {
    @Bindable var controller: VoiceReviewController
    let versionID: UUID
    let engine: URL
    let selected: Bool
    let select: () -> Void
    let seek: (Double) -> Void
    let prepareCandidatePlayback: (UUID) -> Bool
    @State private var visibleNotes = 50
    @State private var reloadTypedDraft = false
    @State private var discardTypedDraft = false
    @Bindable private var composer: VoiceTypedComposer
    init(controller: VoiceReviewController,versionID: UUID,engine: URL,selected: Bool,select: @escaping () -> Void,seek: @escaping (Double) -> Void,prepareCandidatePlayback: @escaping (UUID) -> Bool) {
        self.controller = controller; self.versionID = versionID; self.engine = engine; self.selected = selected
        self.select = select; self.seek = seek; self.prepareCandidatePlayback = prepareCandidatePlayback
        self.composer = controller.typedComposer(for: versionID)
    }

    var body: some View {
        ClautoSection("Feedback") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if !selected { Button("Use this video", action: select).accessibilityIdentifier("voiceReviewSelectPlayer") }
                }
                VStack(alignment: .leading,spacing: 8) {
                    Picker("Microphone", selection: Binding(get: { controller.selectedDeviceUID }, set: controller.chooseDevice)) {
                        Text("Automatic").tag("")
                        if !controller.selectedDeviceUID.isEmpty && !controller.devices.contains(where: { $0.id == controller.selectedDeviceUID }) {
                            Text("Selected microphone unavailable").tag(controller.selectedDeviceUID)
                        }
                        ForEach(controller.devices) { Text($0.name).tag($0.id) }
                    }.disabled(controller.active || controller.voiceSetupPhase.working).accessibilityIdentifier("voiceReviewMicrophone")
                    Button("Refresh") { Task { await controller.refreshAccess() } }
                        .disabled(controller.active || controller.voiceSetupPhase.working).accessibilityIdentifier("voiceReviewRefreshInputs")
                }
                if needsSetup {
                    voiceSetupControls
                }
                VStack(alignment: .leading,spacing: 8) {
                    HStack {
                    if !needsSetup && !controller.active {
                        Button("Start listening") { if !selected { select() }; controller.setUpVoiceReview(for: versionID) }
                            .accessibilityIdentifier("voiceReviewStart")
                    }
                    if controller.canStop {
                    Button("Mic Off") { Task { _ = await controller.stop() } }
                        .disabled(controller.mode == .finishing).accessibilityIdentifier("voiceReviewStop")
                    }
                    }.buttonStyle(.bordered).controlSize(.small)
                    Text(controller.mode.rawValue.capitalized).font(ClautoDesign.caption)
                        .accessibilityLabel("Voice review status").accessibilityValue(controller.mode.rawValue)
                }
                if controller.active {
                    ProgressView("Microphone level", value: Double(controller.level), total: 1)
                        .accessibilityIdentifier("voiceReviewMicrophoneLevel")
                }
                Text("Keep steering. Feedback saves as you speak.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                if controller.nextPacketAt != nil {
                    Text("Next update after two quiet minutes.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                        .accessibilityIdentifier("voiceSteeringWaiting")
                }
                if controller.waitingForPreparation {
                    Text("Waiting for the current update…").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                }
                if let packet = controller.document.feedbackPackets?.last {
                    Text("Update \(packet.number) · \(packet.notes.filter { !$0.cancelled }.count) comments" + (packet.needsAttention > 0 ? " · \(packet.needsAttention) need clarification":" · saved"))
                        .font(ClautoDesign.caption).textSelection(.enabled).accessibilityIdentifier("voiceSteeringPacket")
                }
                if let error = controller.error {
                    Text(error).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled)
                        .accessibilityIdentifier("voiceReviewError")
                }
                if controller.unsavedActions > 0 {
                    HStack {
                        Text("\(controller.unsavedActions) voice-review actions have not saved. Keep Clauto open to retry.")
                        Button("Retry Save") { Task { await controller.retryStorage() } }.accessibilityIdentifier("voiceReviewRetrySave")
                    }.font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                }
                ClautoDisclosure("Typed feedback") {
                    TextField("Feedback", text: $composer.text).accessibilityIdentifier("voiceTypedFeedback")
                    Picker("Explicit review action", selection: $composer.action) {
                        Text("Protect this range").tag(VoiceRangeAction.protect)
                        Text("Remove this range").tag(VoiceRangeAction.remove)
                    }
                    VStack(alignment: .leading) {
                        TextField("Start seconds", text: $composer.start).accessibilityLabel("Typed feedback start seconds")
                        TextField("End seconds", text: $composer.end).accessibilityLabel("Typed feedback end seconds")
                        Button("Save typed review note") {
                            controller.submitTypedComposer(versionID)
                        }.disabled(composer.saving || !selected || controller.target?.versionID != versionID || composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("voiceSaveTypedFeedback")
                    }
                    if composer.hasEdits {
                        Button("Discard draft…") { discardTypedDraft = true }
                            .confirmationDialog("Discard this unfinished feedback?",isPresented: $discardTypedDraft) {
                                Button("Discard draft",role: .destructive) { controller.discardTypedComposer(versionID) }
                            }
                            .accessibilityIdentifier("voiceDiscardTypedDraft")
                    }
                    if let issue = composer.storageIssue {
                        Text(issue).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled)
                        Button("Reload saved draft…") { reloadTypedDraft = true }
                            .confirmationDialog("Replace this unsaved draft? Copy any text you want to keep first.",isPresented: $reloadTypedDraft) {
                                Button("Reload saved draft",role: .destructive) { controller.reloadTypedComposer(versionID) }
                            }
                    } else if composer.hasEdits {
                        Text(controller.dirtyTypedVersions.contains(versionID) ? "Draft saving…":"Draft saved").font(ClautoDesign.caption).textSelection(.enabled)
                    }
                }.disabled(composer.saving)
                if controller.renderingCandidateID != nil {
                    ProgressView(controller.renderProgress)
                    Button("Cancel candidate render") { Task { await controller.cancelRender() } }.accessibilityIdentifier("voiceCancelCandidateRender")
                }
                ForEach(Array(controller.visibleCards.suffix(visibleNotes).reversed())) { note in
                    VoiceReviewNoteRow(controller: controller, note: note, versionID: versionID, seek: seek)
                }
                if controller.visibleCards.count > visibleNotes {
                    Button("Show earlier feedback") { visibleNotes += 50 }.accessibilityIdentifier("voiceReviewEarlierFeedback")
                }
                if !controller.document.candidates.isEmpty {
                    ClautoDisclosure("Separate candidate history", expandedByDefault: true) {
                        ForEach(Array(controller.document.candidates.suffix(8).reversed())) { candidate in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Candidate for v\(candidate.parent.versionNumber) · \(candidate.state.rawValue)").font(ClautoDesign.body)
                                Text(candidate.detail).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                                VoiceCandidateActions(controller: controller,candidate: candidate,engine: engine,selected: selected,preparePlayback: prepareCandidatePlayback)
                                ForEach(candidate.directives, id: \.noteID) { directive in
                                    Text(String(format: "%.3fs · %@ · %@", directive.anchor.seconds,
                                        directive.intent == .protect ? "Protect" : "Change requested", directive.text)).font(ClautoDesign.caption)
                                }
                            }.accessibilityElement(children: .contain).accessibilityLabel("Candidate for version \(candidate.parent.versionNumber), \(candidate.state.rawValue)")
                        }
                    }
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var needsSetup: Bool {
        controller.voiceSetupPhase.working || controller.voiceSetupPhase == .failed ||
        (!controller.active && (controller.access?.canStart != true || !controller.devices.contains { $0.id == controller.selectedDeviceUID }))
    }
    private var voiceSetupControls: some View {
        VStack(alignment: .leading,spacing: 8) {
            if controller.voiceSetupPhase.working {
                Text(controller.voiceSetupPhase.label).font(ClautoDesign.caption).textSelection(.enabled)
                if controller.voiceSetupPhase == .model {
                    ProgressView(value: controller.voiceSetupProgress ?? 0,total: 1).accessibilityLabel("Preparing on-device speech")
                    Text(controller.voiceSetupProgress.map { "\(Int($0*100))%" } ?? "Preparing…").font(ClautoDesign.caption).monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Button("Cancel setup") { controller.cancelVoiceSetup() }
            } else {
                Text(controller.voiceSetupIssue ?? "Allow access once. Clauto prepares voice recognition on this Mac.").font(ClautoDesign.caption).textSelection(.enabled)
                if let permission = controller.voiceSetupPermission {
                    Button("Allow "+(permission == "Microphone" ? "Microphone":"Speech Recognition")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_"+permission) { NSWorkspace.shared.open(url) }
                    }
                }
                Button(controller.voiceSetupPhase == .failed ? "Try again":"Get started") {
                    if !selected { select() }
                    controller.setUpVoiceReview(for: versionID)
                }.accessibilityIdentifier("voiceReviewGetStarted")
            }
        }
    }
}

private struct VoiceReviewNoteRow: View {
    @Bindable var controller: VoiceReviewController
    let note: VoiceReviewNote
    let versionID: UUID
    let seek: (Double) -> Void
    // Deliberate editing draft: later ASR never replaces text while the user types.
    @State private var text: String
    @State private var action: VoiceRangeAction?
    @State private var intent: VoiceIntent
    @State private var targetID: UUID?
    @State private var start: String
    @State private var end: String
    @State private var baseRevision: Int
    @State private var dirty = false
    @Bindable private var cardInput: VoiceCardInput

    init(controller: VoiceReviewController, note: VoiceReviewNote, versionID: UUID, seek: @escaping (Double) -> Void) {
        self.controller = controller; self.note = note; self.versionID = versionID; self.seek = seek
        self.cardInput = controller.cardInput(for: note.id)
        let draft = controller.drafts[note.id]
        _text = State(initialValue: draft?.text ?? note.text); _intent = State(initialValue: draft?.intent ?? note.intent)
        _action = State(initialValue: draft?.action ?? note.action)
        _targetID = State(initialValue: draft?.targetID ?? note.effectiveAnchor?.targetID ?? note.lineage?.parentAnchors.first?.targetID)
        _start = State(initialValue: draft?.start ?? note.effectiveAnchor.map { String(format: "%.6f", $0.seconds) } ?? "")
        _end = State(initialValue: draft?.end ?? note.effectiveAnchor?.endSeconds.map { String(format: "%.6f", $0) } ?? "")
        _baseRevision = State(initialValue: draft?.baseRevision ?? note.revision)
        _dirty = State(initialValue: draft != nil)
    }
    private var retired: Bool { !(note.supersededBy ?? []).isEmpty }
    private var nextCard: VoiceReviewNote? {
        let cards = controller.document.orderedVisibleNotes.filter { $0.state != .cancelled }
        guard let index = cards.firstIndex(where: { $0.id == note.id }), index+1 < cards.count else { return nil }
        let next = cards[index+1]
        return next.isFinal && next.effectiveAnchor?.targetID == note.effectiveAnchor?.targetID ? next : nil
    }
    private var boundTarget: VoiceReviewTarget? { controller.document.targets.first { $0.id == note.effectiveAnchor?.targetID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if retired {
                Text("This card was merged or split. Your unsaved draft is retained here for copying.").font(.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled)
                Button("Discard retained draft") { controller.discardDraft(note.id) }
            }
            HStack {
                Text(boundTarget.map { "v\($0.versionNumber)" } ?? "Timing needs resolution").font(ClautoDesign.body)
                if let anchor = note.effectiveAnchor {
                    Button(String(format: "Go to %.3fs", anchor.seconds)) { seek(anchor.seconds) }
                        .disabled(boundTarget?.versionID != versionID)
                        .accessibilityLabel("Go to feedback at \(anchor.seconds) seconds in version \(boundTarget?.versionNumber ?? 0)")
                }
                Spacer()
                Text(note.state.rawValue).font(ClautoDesign.caption).foregroundStyle(note.issues.isEmpty ? ClautoDesign.quiet : ClautoDesign.ember)
            }
            if retired {
                Text(text).font(ClautoDesign.body).textSelection(.enabled)
                    .accessibilityLabel("Retained voice feedback draft")
            } else {
                TextEditor(text: Binding(get: { text }, set: { text = $0; changed() }))
                    .frame(minHeight: 58, maxHeight: 110).font(ClautoDesign.body)
                    .accessibilityLabel("Voice feedback transcript").accessibilityIdentifier("voiceReviewTranscript-" + note.id.uuidString)
            }
            Picker("Meaning", selection: Binding(get: { intent }, set: { intent = $0; changed() })) {
                Text("Protect / like").tag(VoiceIntent.protect)
                Text("Change / dislike").tag(VoiceIntent.change)
                Text("Clarify").tag(VoiceIntent.unclear)
            }.disabled(retired).accessibilityIdentifier("voiceReviewIntent-" + note.id.uuidString)
            Picker("Action", selection: Binding(get: { action },set: { action = $0; changed() })) {
                Text("Choose action").tag(Optional<VoiceRangeAction>.none)
                Text("Protect range").tag(Optional(VoiceRangeAction.protect))
                Text("Remove range").tag(Optional(VoiceRangeAction.remove))
            }.disabled(retired).accessibilityIdentifier("voiceReviewAction-"+note.id.uuidString)
            ForEach(note.issues, id: \.self) { Text($0).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
            if !retired && dirty && baseRevision != note.revision {
                Text("This note changed while you edited. Your draft is retained; reload the latest note before saving.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                Button("Reload latest note") { controller.discardDraft(note.id); reload() }
            }
            HStack {
                Button("Save") { save(anchor: nil) }.disabled(retired || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseRevision != note.revision)
                Button("Cancel") { Task { await controller.cancel(note) } }.disabled(retired || note.state == .cancelled)
                Button("Retry") { Task { await controller.retry(note) } }.disabled(retired || !note.isFinal || ![.failed,.cancelled].contains(note.state))
            }.buttonStyle(.bordered).controlSize(.small)
            if !retired {
                ClautoDisclosure("Merge / split") {
                    if let next = nextCard {
                        Button("Merge with next card") {
                            controller.restructureCards(.init(id: UUID(),kind: .merge,parents: [.init(id: note.id,revision: note.revision),.init(id: next.id,revision: next.revision)]))
                        }.disabled(dirty || !note.isFinal)
                    }
                    TextField("Split after this opening phrase",text: $cardInput.splitAfter)
                        .accessibilityLabel("Split card after opening phrase")
                    Button("Split card") {
                        let prefix = cardInput.splitAfter
                        guard !prefix.isEmpty, text.hasPrefix(prefix) else { controller.error = "Enter the opening phrase exactly; both new cards need text."; return }
                        controller.restructureCards(.init(id: UUID(),kind: .split,parents: [.init(id: note.id,revision: note.revision)],splitUTF16: prefix.utf16.count))
                    }.disabled(dirty || !note.isFinal || cardInput.splitAfter.isEmpty)
                    Text("Original words and anchors stay in history. Confirm each new card's range and action.").font(.caption).foregroundStyle(ClautoDesign.quiet).textSelection(.enabled)
                }
            }
            ClautoDisclosure("Timing and transcript history") {
                Picker("Saved version for this feedback", selection: Binding(get: { targetID }, set: { targetID = $0; changed() })) {
                    Text("Choose a saved version").tag(Optional<UUID>.none)
                    ForEach(controller.document.targets) { Text("v\($0.versionNumber)").tag(Optional($0.id)) }
                }.disabled(retired)
                VStack(alignment: .leading,spacing: 8) {
                    TextField("Start seconds", text: Binding(get: { start }, set: { start = $0; changed() })).accessibilityLabel("Feedback start seconds")
                    TextField("End seconds (optional)", text: Binding(get: { end }, set: { end = $0; changed() })).accessibilityLabel("Feedback end seconds, optional")
                    Button("Resolve timing and save") {
                        guard let targetID, let seconds = Double(start), end.isEmpty || Double(end) != nil else { controller.error = "Choose the exact saved version and valid seconds."; return }
                        save(anchor: .init(targetID: targetID, seconds: seconds, endSeconds: end.isEmpty ? nil : Double(end)))
                    }.disabled(retired || baseRevision != note.revision)
                }.disabled(retired)
                if let lineage = note.lineage {
                    Text("\(lineage.operation.kind.rawValue.capitalized) · \(lineage.operation.parents.count) original cards").font(.caption)
                    ForEach(Array(lineage.parentAnchors.enumerated()),id: \.offset) { _,anchor in
                        Text(String(format: "Original anchor %.6f%@",anchor.seconds,anchor.endSeconds.map { String(format: "–%.6f",$0) } ?? "")).font(.caption.monospacedDigit()).textSelection(.enabled)
                    }
                }
                Text("Original ASR: " + note.transcript).font(ClautoDesign.caption).textSelection(.enabled)
                ForEach(note.history) { entry in
                    Text("\(entry.source) · r\(entry.revision): \(entry.text)").font(ClautoDesign.caption).textSelection(.enabled)
                }
            }
        }.disabled(controller.restructuringCards.contains(note.id)).padding(10).background(ClautoDesign.paper).accessibilityElement(children: .contain)
            .accessibilityLabel("Voice feedback, " + (boundTarget.map { "version \($0.versionNumber)" } ?? "unresolved version"))
            .onChange(of: note.revision) { if !dirty { reload() } }
    }
    private func changed() {
        dirty = true
        controller.retainDraft(.init(noteID: note.id, text: text, intent: intent, targetID: targetID, start: start, end: end, baseRevision: baseRevision, action: action))
    }
    private func reload(_ saved: VoiceReviewNote? = nil) {
        let note = saved ?? controller.document.notes.first(where: { $0.id == self.note.id }) ?? self.note
        text = note.text; intent = note.intent; action = note.action; targetID = note.effectiveAnchor?.targetID
        start = note.effectiveAnchor.map { String(format: "%.6f", $0.seconds) } ?? ""
        end = note.effectiveAnchor?.endSeconds.map { String(format: "%.6f", $0) } ?? ""
        baseRevision = note.revision; dirty = false
    }
    private func save(anchor: VoiceNoteAnchor?) {
        let draft = text, meaning = intent, revision = baseRevision, draftStart = start, draftEnd = end, draftTarget = targetID, submittedAction = action
        Task {
            if await controller.edit(note, text: draft, intent: meaning, anchor: anchor, expectedRevision: revision, action: submittedAction) {
                // Keep a newer draft if typing continued while this write awaited disk.
                if text == draft && intent == meaning && start == draftStart && end == draftEnd && targetID == draftTarget && action == submittedAction { reload() }
                else if let saved = controller.document.notes.first(where: { $0.id == note.id }) { baseRevision = saved.revision; changed() }
            }
        }
    }
}

private struct VoiceCandidateActions: View {
    @Bindable var controller: VoiceReviewController
    let candidate: VoiceRevisionCandidate
    let engine: URL
    let selected: Bool
    let preparePlayback: (UUID) -> Bool
    @State private var playbackToken = UUID()
    @State private var previewURL: URL?
    @State private var showingPreview = false
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            if candidate.state == .prepared {
                if let plan = candidate.editPlan {
                    Text("Review candidate from the watched movie. Original camera/graphics timeline is retained separately as reference.")
                        .font(ClautoDesign.caption)
                    ForEach(Array(plan.operations.enumerated()),id: \.offset) { _, operation in
                        Text("\(operation.action == .protect ? "Protect" : "Remove") watched frames \(operation.startFrame)..<\(operation.endFrame) · note \(operation.noteID.uuidString.prefix(8))")
                            .font(ClautoDesign.caption).textSelection(.enabled)
                    }
                    Text("Removals round inward and protections outward to complete 24000/1001 video frames. All ranges refer to the watched version before any cuts.").font(ClautoDesign.caption)
                    ForEach(plan.issues,id: \.self) { Text($0).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
                    if plan.issues.isEmpty, let sha = candidate.editPlanSHA256 {
                        Text("Plan "+sha.prefix(12)).font(ClautoDesign.caption)
                        if candidate.editApproval == nil {
                            Button(controller.approvingCandidateIDs.contains(candidate.id) ? "Preparing preview…":"Approve and create preview") { Task { await controller.approveEditPlan(candidate,engine: engine) } }
                                .disabled(!controller.approvingCandidateIDs.isEmpty || controller.renderingCandidateID != nil)
                                .accessibilityIdentifier("voiceApproveCandidatePlan")
                        } else {
                            Text("Rendering uses one private temporary local copy, up to 1 GiB; the completed candidate stays in this project on your drive.").font(ClautoDesign.caption)
                            if controller.renderingCandidateID != candidate.id {
                                Button(candidate.renderedPreview == nil ? "Retry preview" : "Create another preview") { controller.renderPreview(candidate,engine: engine) }
                                    .disabled(!controller.approvingCandidateIDs.isEmpty || controller.renderingCandidateID != nil).accessibilityIdentifier("voiceRenderCandidate")
                            }
                        }
                    }
                } else {
                    Button("Review exact candidate cuts") { Task { await controller.prepareEditPlan(candidate) } }
                        .accessibilityIdentifier("voicePrepareCandidatePlan")
                }
            }
            if let rendered = candidate.renderedPreview {
                Text("Verified candidate · \(rendered.frames) frames · watched version unchanged").font(ClautoDesign.caption)
                Button("Play verified review candidate") {
                    Task {
                        do {
                            let verified = try await controller.repository.verifiedPreview(candidate.id)
                            guard preparePlayback(playbackToken) else { return }
                            previewURL = verified; showingPreview = true
                        }
                        catch { controller.error = error.localizedDescription }
                    }
                }.disabled(!selected || !controller.canPresentCandidate).accessibilityIdentifier("voicePlayCandidate")
                Button("Reveal rendered review candidate") {
                    Task {
                        do { let url = try await controller.repository.verifiedPreview(candidate.id); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        catch { controller.error = error.localizedDescription }
                    }
                }.accessibilityIdentifier("voiceRevealCandidate")
            }
        }.sheet(isPresented: $showingPreview,onDismiss: { controller.endCandidatePlayback(playbackToken) }) {
            if let previewURL { VoiceCandidatePlayback(url: previewURL).clautoThemeAppearance() }
        }.onDisappear { controller.endCandidatePlayback(playbackToken) }
    }
}

private struct VoiceCandidatePlayback: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var seconds = 0.0
    @State private var playing = false
    @State private var ready = false
    @State private var failure: String?
    @State private var control = ReviewPlaybackControl()
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("Separate review candidate").font(.headline)
            Text("Review playback only; voice feedback is disabled here. The watched version is paused and unchanged. Original camera and graphics layers remain in the preserved parent timeline.").font(.caption)
            CutPreview(url: url,playhead: $seconds,playing: $playing,ready: $ready,failure: $failure,control: control,onSeekCompleted: { _ in },onTimeJump: {})
                .frame(minWidth: 800,minHeight: 450)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button(playing ? "Pause candidate" : "Play candidate") { if playing { control.player?.pause() } else { control.player?.play() } }.disabled(!ready || failure != nil)
                Text(String(format: "%.2f s",seconds)).monospacedDigit()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth: 860,minHeight: 580)
        .onDisappear { control.player?.pause() }
    }
}
