import SwiftUI
import AppKit

struct ScriptNewVersionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Untitled script"
    @State private var author = "Local editor"
    @State private var model = ""
    @State private var input: Data?
    @State private var inputName = ""
    @State private var error: String?
    @State private var saving = false
    var failure: String?
    let save: (String, ScriptProvenance, Data?) async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Independent script version").font(ClautoDesign.heading).accessibilityAddTraits(.isHeader)
            Text("Begin empty or import a real source-bound JSON response. Recorded words must match whole transcript passages. New speech belongs in pickups.").font(ClautoDesign.caption)
            ClautoField(label: "Version title", text: $title)
            ClautoField(label: "Private author attribution", text: $author)
            ClautoField(label: "Private model attribution (if used)", text: $model, placeholder: "User supplied; model identity is not verified")
            Button(input == nil ? "Choose source-bound script JSON…" : "Change imported JSON…") {
                Task {
                    if let url = await FileDialogs.sourceBoundScript() {
                        do {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                            guard size <= 8 * 1024 * 1024 else { throw WorkflowFailure.invalid("Choose a JSON file smaller than 8 MB.") }
                            input = try Data(contentsOf: url); inputName = url.lastPathComponent; error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            if input != nil { HStack { Text(inputName).font(ClautoDesign.caption); Button("Use an empty draft") { input = nil; inputName = "" } } }
            if let error { Text(error).foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption) }
            if let failure { Text(failure).foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption).fixedSize(horizontal: false, vertical: true) }
            Text("Author and model details are stored locally for traceability and hidden during blind scoring. No model is called by importing a file.").font(ClautoDesign.caption)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "Saving…" : "Create version") {
                    saving = true
                    Task { await save(title, .init(author: author, model: model, origin: input == nil ? "Locally authored" : "Imported JSON; user supplied attribution"), input); saving = false }
                }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("createIndependentScript")
            }
        }.padding(26).frame(width: 580).font(ClautoDesign.body).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).buttonStyle(ClautoButtonStyle()).clautoThemeAppearance()
    }
}

struct ScriptBeatRow: View {
    let beat: ScriptBeat
    let position: Int
    let row: TranscriptRow?
    let first: Bool
    let last: Bool
    let edit: () -> Void
    let move: (Int) -> Void
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(position). \(beat.heading.isEmpty ? "Recorded passage" : beat.heading)").font(ClautoDesign.type(16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(beat.kind == .pickup ? "UNRECORDED PICKUP · no source audio" : "\(row?.sourceID ?? "Missing source") · \(row?.inTimecode ?? "")–\(row?.outTimecode ?? "")").font(ClautoDesign.caption).foregroundStyle(beat.kind == .pickup ? ClautoDesign.ember : ClautoDesign.quiet)
            Text(beat.kind == .pickup ? beat.unrecordedText : row?.text ?? "Source unavailable").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !beat.notes.isEmpty { Text(beat.notes).font(ClautoDesign.caption).textSelection(.enabled) }
            HStack {
                Button("Move up") { move(-1) }.disabled(first).accessibilityLabel("Move beat \(position) up")
                Button("Move down") { move(1) }.disabled(last).accessibilityLabel("Move beat \(position) down")
                Button("Edit notes") { edit() }.accessibilityLabel("Edit beat \(position) notes")
                Spacer()
                Button("Remove from version") { remove() }.accessibilityLabel("Remove beat \(position) from this version")
            }
        }.padding(16).background(ClautoDesign.sheet).accessibilityElement(children: .contain)
    }
}

struct ScriptBeatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScriptBeat
    @State private var saving = false
    let isNew: Bool
    var failure: String?
    let save: (ScriptBeat) async -> Void
    init(beat: ScriptBeat, isNew: Bool, failure: String? = nil, save: @escaping (ScriptBeat) async -> Void) {
        _draft = State(initialValue: beat); self.isNew = isNew; self.failure = failure; self.save = save
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.kind == .pickup ? "Unrecorded pickup" : "Recorded passage notes").font(ClautoDesign.heading)
            if !isNew { ClautoField(label: "Beat heading", text: $draft.heading) }
            if draft.kind == .pickup { ClautoTextArea(text: $draft.unrecordedText, label: "Wording to record").frame(height: 150) }
            else { Text("Recorded speech is immutable. Add proposed new wording as a separate pickup.").font(ClautoDesign.caption) }
            if !isNew { ClautoTextArea(text: $draft.notes, label: "Editorial notes and fact questions").frame(height: 130) }
            if let failure { Text(failure).foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Save beat") { saving = true; Task { await save(draft); saving = false } }
                    .disabled(saving || (draft.kind == .pickup && draft.unrecordedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(26).frame(width: 590).font(ClautoDesign.body).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).buttonStyle(ClautoButtonStyle()).clautoThemeAppearance()
    }
}

struct ScriptPassagePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var saving = false
    let catalog: TranscriptCatalog
    let selected: Set<String>
    let add: (String) async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add recorded speech").font(ClautoDesign.heading)
            ClautoField(label: "Find a passage", text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(catalog.rows.filter { query.isEmpty || $0.text.localizedStandardContains(query) || $0.sourceID.localizedStandardContains(query) }) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(row.sourceID) · \(row.inTimecode)–\(row.outTimecode)").font(ClautoDesign.caption)
                            Text(row.text).textSelection(.enabled)
                            Button(selected.contains(row.id) ? "Already in this version" : "Add passage") { saving = true; Task { await add(row.id); saving = false } }.disabled(saving || selected.contains(row.id)).accessibilityLabel("Add \(row.sourceID) passage \(row.originalOrder)")
                        }.padding(14).background(ClautoDesign.sheet)
                    }
                }
            }.scrollIndicators(.visible)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(26).frame(width: 660, height: 620).font(ClautoDesign.body).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).buttonStyle(ClautoButtonStyle()).clautoThemeAppearance()
    }
}

struct ScriptDispositionRow: View {
    let file: ProjectFile
    let current: String
    @State private var note: String
    let save: (String) async -> Bool
    init(file: ProjectFile, current: String, save: @escaping (String) async -> Bool) {
        self.file = file; self.current = current; self.save = save; _note = State(initialValue: current)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(file.name).font(ClautoDesign.type(15, weight: .semibold))
            ClautoField(label: "Reviewed media disposition", text: $note, placeholder: "For example: reviewed B-roll; no relevant speech")
            Button("Save disposition") { Task { _ = await save(note) } }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note == current)
            if !current.isEmpty { Text("Saved: \(current)").font(ClautoDesign.caption) }
        }.padding(14).background(ClautoDesign.sheet).onChange(of: current) { note = current }
    }
}

struct ScriptBlindCard: View {
    let option: BlindScriptOption
    let locked: Bool
    let score: (ScriptScore) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(option.label).font(ClautoDesign.type(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ForEach(option.lines, id: \.position) { line in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(line.position). \(line.heading)").font(ClautoDesign.type(15, weight: .semibold))
                    Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(line.source).font(ClautoDesign.caption).foregroundStyle(line.pickup ? ClautoDesign.ember : ClautoDesign.quiet)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { scoring }
                VStack(alignment: .leading) { scoring }
            }.disabled(locked)
            Text(locked ? "Scores locked" : "Choose a score for all three criteria").font(ClautoDesign.caption)
        }.padding(18).background(ClautoDesign.sheet).accessibilityElement(children: .contain).accessibilityIdentifier("blindScriptOption")
    }
    @ViewBuilder private var scoring: some View {
        scoreChoice("Clarity", key: \.clarity)
        scoreChoice("Story", key: \.story)
        scoreChoice("Source coverage", key: \.coverage)
    }
    private func scoreChoice(_ title: String, key: WritableKeyPath<ScriptScore, Int>) -> some View {
        ClautoChoice(title: "\(option.label) · \(title)", selection: Binding(get: { option.score[keyPath: key] }, set: { value in var changed = option.score; changed[keyPath: key] = value; score(changed) }), options: [(0, "Unscored")] + (1...5).map { ($0, "\($0) / 5") })
    }
}

struct ScriptRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    let save: (String) async -> Void
    init(title: String, save: @escaping (String) async -> Void) { _title = State(initialValue: title); self.save = save }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ClautoField(label: "Version title", text: $title)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save title") { Task { await save(title) } }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(26).frame(width: 460).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).buttonStyle(ClautoButtonStyle()).clautoThemeAppearance()
    }
}
