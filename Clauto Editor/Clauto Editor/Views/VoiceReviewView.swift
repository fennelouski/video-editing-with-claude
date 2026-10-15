import SwiftUI

struct VoiceReviewView: View {
    @Bindable var controller: VoiceReviewController
    let versionID: UUID
    let selected: Bool
    let select: () -> Void
    let seek: (Double) -> Void
    @State private var visibleNotes = 50

    var body: some View {
        ClautoSection("Voice review") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review with headphones. Speak while watching or paused; each note keeps its saved version and speech-onset time.")
                    .font(ClautoDesign.body)
                HStack {
                    Button(selected ? "This player is selected for Voice Review" : "Use this player for Voice Review", action: select)
                        .disabled(selected).accessibilityIdentifier("voiceReviewSelectPlayer")
                }
                HStack {
                    Picker("Microphone", selection: Binding(get: { controller.selectedDeviceUID }, set: controller.chooseDevice)) {
                        Text("Choose a microphone").tag("")
                        if !controller.selectedDeviceUID.isEmpty && !controller.devices.contains(where: { $0.id == controller.selectedDeviceUID }) {
                            Text("Selected microphone unavailable").tag(controller.selectedDeviceUID)
                        }
                        ForEach(controller.devices) { Text($0.name).tag($0.id) }
                    }.disabled(controller.active).accessibilityIdentifier("voiceReviewMicrophone")
                    Button("Refresh inputs") { Task { await controller.refreshAccess() } }
                        .disabled(controller.active).accessibilityIdentifier("voiceReviewRefreshInputs")
                }
                if let access = controller.access {
                    if access.microphone != .authorized {
                        Text(access.microphone == .denied ? "Microphone access is off. Enable Clauto in System Settings before recording." : "Microphone access has not been requested.")
                            .font(ClautoDesign.caption)
                        if access.microphone == .notDetermined {
                            Button("Allow Microphone Access…") { Task { await controller.requestMicrophonePermission() } }
                                .accessibilityIdentifier("voiceReviewGrantMicrophone")
                        }
                    }
                    if access.speech != .authorized {
                        Text(access.speech == .denied ? "Speech Recognition access is off. Enable Clauto in System Settings." : "Speech Recognition access has not been requested.")
                            .font(ClautoDesign.caption)
                        if access.speech == .notDetermined {
                            Button("Allow Speech Recognition…") { Task { await controller.requestSpeechPermission() } }
                                .accessibilityIdentifier("voiceReviewGrantSpeech")
                        }
                    }
                    if !access.installedModel {
                        Text("The local speech model for \(access.locale) is unavailable. Install it through Dictate, then refresh. Clauto will not start a download.")
                            .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                    }
                }
                HStack {
                    Button("Start Voice Review") { controller.start() }
                        .disabled(!selected || !controller.canStart || controller.target?.versionID != versionID).accessibilityIdentifier("voiceReviewStart")
                    Button("Stop and Finalize") { Task { _ = await controller.stop() } }
                        .disabled(!controller.canStop || controller.mode == .finishing).accessibilityIdentifier("voiceReviewStop")
                    Button("Cancel capture") { Task { _ = await controller.stop(cancel: true) } }
                        .disabled(!controller.canStop || controller.mode == .finishing).accessibilityIdentifier("voiceReviewCancelCapture")
                    Text(controller.mode.rawValue.capitalized).font(ClautoDesign.caption)
                        .accessibilityLabel("Voice review status").accessibilityValue(controller.mode.rawValue)
                }
                if controller.active {
                    ProgressView("Microphone level", value: Double(controller.level), total: 1)
                        .accessibilityIdentifier("voiceReviewMicrophoneLevel")
                }
                Text("Audio is transcribed on this Mac. Transcripts, editing drafts and review history are retained. Drafts become instructions only after Save. Completed notes prepare separate candidate instructions while you continue; a new cut still needs approved rendering and verification.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
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
                ForEach(Array(controller.document.notes.suffix(visibleNotes).reversed())) { note in
                    VoiceReviewNoteRow(controller: controller, note: note, versionID: versionID, seek: seek)
                }
                if controller.document.notes.count > visibleNotes {
                    Button("Show earlier feedback") { visibleNotes += 50 }.accessibilityIdentifier("voiceReviewEarlierFeedback")
                }
                if !controller.document.candidates.isEmpty {
                    ClautoDisclosure("Separate candidate history", expandedByDefault: true) {
                        ForEach(Array(controller.document.candidates.suffix(8).reversed())) { candidate in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Candidate for v\(candidate.parent.versionNumber) · \(candidate.state.rawValue)").font(ClautoDesign.body)
                                Text(candidate.detail).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
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
}

private struct VoiceReviewNoteRow: View {
    @Bindable var controller: VoiceReviewController
    let note: VoiceReviewNote
    let versionID: UUID
    let seek: (Double) -> Void
    // Deliberate editing draft: later ASR never replaces text while the user types.
    @State private var text: String
    @State private var intent: VoiceIntent
    @State private var targetID: UUID?
    @State private var start: String
    @State private var end: String
    @State private var baseRevision: Int
    @State private var dirty = false

    init(controller: VoiceReviewController, note: VoiceReviewNote, versionID: UUID, seek: @escaping (Double) -> Void) {
        self.controller = controller; self.note = note; self.versionID = versionID; self.seek = seek
        let draft = controller.drafts[note.id]
        _text = State(initialValue: draft?.text ?? note.text); _intent = State(initialValue: draft?.intent ?? note.intent)
        _targetID = State(initialValue: draft?.targetID ?? note.effectiveAnchor?.targetID)
        _start = State(initialValue: draft?.start ?? note.effectiveAnchor.map { String(format: "%.6f", $0.seconds) } ?? "")
        _end = State(initialValue: draft?.end ?? note.effectiveAnchor?.endSeconds.map { String(format: "%.6f", $0) } ?? "")
        _baseRevision = State(initialValue: draft?.baseRevision ?? note.revision)
        _dirty = State(initialValue: draft != nil)
    }
    private var boundTarget: VoiceReviewTarget? { controller.document.targets.first { $0.id == note.effectiveAnchor?.targetID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            TextEditor(text: Binding(get: { text }, set: { text = $0; changed() }))
                .frame(minHeight: 58, maxHeight: 110).font(ClautoDesign.body)
                .accessibilityLabel("Voice feedback transcript").accessibilityIdentifier("voiceReviewTranscript-" + note.id.uuidString)
            Picker("Feedback meaning", selection: Binding(get: { intent }, set: { intent = $0; changed() })) {
                Text("Protect / like").tag(VoiceIntent.protect)
                Text("Change / dislike").tag(VoiceIntent.change)
                Text("Needs clarification").tag(VoiceIntent.unclear)
            }.accessibilityIdentifier("voiceReviewIntent-" + note.id.uuidString)
            ForEach(note.issues, id: \.self) { Text($0).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
            if dirty && baseRevision != note.revision {
                Text("This note changed while you edited. Your draft is retained; reload the latest note before saving.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
                Button("Reload latest note") { controller.discardDraft(note.id); reload() }
            }
            HStack {
                Button("Save transcript") { save(anchor: nil) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseRevision != note.revision)
                Button("Cancel processing") { Task { await controller.cancel(note) } }.disabled(note.state == .cancelled)
                Button("Retry preparation") { Task { await controller.retry(note) } }.disabled(!note.isFinal || ![.failed,.cancelled].contains(note.state))
            }
            ClautoDisclosure("Timing and transcript history") {
                Picker("Saved version for this feedback", selection: Binding(get: { targetID }, set: { targetID = $0; changed() })) {
                    Text("Choose a saved version").tag(Optional<UUID>.none)
                    ForEach(controller.document.targets) { Text("v\($0.versionNumber)").tag(Optional($0.id)) }
                }
                HStack {
                    TextField("Start seconds", text: Binding(get: { start }, set: { start = $0; changed() })).accessibilityLabel("Feedback start seconds")
                    TextField("End seconds (optional)", text: Binding(get: { end }, set: { end = $0; changed() })).accessibilityLabel("Feedback end seconds, optional")
                    Button("Resolve timing and save") {
                        guard let targetID, let seconds = Double(start), end.isEmpty || Double(end) != nil else { controller.error = "Choose the exact saved version and valid seconds."; return }
                        save(anchor: .init(targetID: targetID, seconds: seconds, endSeconds: end.isEmpty ? nil : Double(end)))
                    }.disabled(baseRevision != note.revision)
                }
                Text("Original ASR: " + note.transcript).font(ClautoDesign.caption).textSelection(.enabled)
                ForEach(note.history) { entry in
                    Text("\(entry.source) · r\(entry.revision): \(entry.text)").font(ClautoDesign.caption).textSelection(.enabled)
                }
            }
        }.padding(10).background(ClautoDesign.paper).accessibilityElement(children: .contain)
            .accessibilityLabel("Voice feedback, " + (boundTarget.map { "version \($0.versionNumber)" } ?? "unresolved version"))
            .onChange(of: note.revision) { if !dirty { reload() } }
    }
    private func changed() {
        dirty = true
        controller.retainDraft(.init(noteID: note.id, text: text, intent: intent, targetID: targetID, start: start, end: end, baseRevision: baseRevision))
    }
    private func reload(_ saved: VoiceReviewNote? = nil) {
        let note = saved ?? controller.document.notes.first(where: { $0.id == self.note.id }) ?? self.note
        text = note.text; intent = note.intent; targetID = note.effectiveAnchor?.targetID
        start = note.effectiveAnchor.map { String(format: "%.6f", $0.seconds) } ?? ""
        end = note.effectiveAnchor?.endSeconds.map { String(format: "%.6f", $0) } ?? ""
        baseRevision = note.revision; dirty = false
    }
    private func save(anchor: VoiceNoteAnchor?) {
        let draft = text, meaning = intent, revision = baseRevision, draftStart = start, draftEnd = end, draftTarget = targetID
        Task {
            if await controller.edit(note, text: draft, intent: meaning, anchor: anchor, expectedRevision: revision) {
                // Keep a newer draft if typing continued while this write awaited disk.
                if text == draft && intent == meaning && start == draftStart && end == draftEnd && targetID == draftTarget { reload() }
                else if let saved = controller.document.notes.first(where: { $0.id == note.id }) { baseRevision = saved.revision; changed() }
            }
        }
    }
}
