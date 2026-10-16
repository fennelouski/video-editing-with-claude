import SwiftUI
import AVKit

struct DerivativeView: View {
    @Bindable var store: EditorStore
    var project: Project
    var version: CutVersion
    var expandedByDefault = false
    @State private var request = DerivativeRequest()
    @State private var start = "0"
    @State private var end = ""
    @State private var audioEnabled = false
    @State private var audio = LocalAudioEffects()
    @State private var highpass = false
    @State private var echo = false
    @State private var selectedExport: UUID?
    @State private var graphicChoices: [GraphicCutChoice] = []
    @State private var graphicLoading = false
    @State private var graphicError: String?
    @State private var graphicLoadID = UUID()
    @State private var savedDuration: Double?

    var body: some View {
        ClautoDisclosure("Export this saved version / make a vertical cut", expandedByDefault: expandedByDefault) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Creates a separate, verified export and editable timeline from v\(version.number). The saved parent stays available.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                HStack {
                    ClautoChoice(title: "Output", selection: $request.aspect, options: [("9:16", "9:16 · portrait"), ("16:9", "16:9 · landscape")])
                    ClautoChoice(title: "Resolution", selection: $request.resolution, options: ExportResolution.allCases.map { ($0, $0.label) })
                }
                HStack {
                    ClautoField(label: "Start seconds", text: $start).accessibilityIdentifier("derivativeStart")
                    ClautoField(label: "End seconds", text: $end, placeholder: "Blank uses the end of the cut").accessibilityIdentifier("derivativeEnd")
                }
                ClautoChoice(title: "Picture framing", selection: $request.framing, options: [("fit", "Fit entire picture"), ("fill", "Fill canvas / crop")])
                HStack {
                    ClautoNumberField(label: "Horizontal position %", value: $request.x)
                    ClautoNumberField(label: "Vertical position %", value: $request.y)
                }
                Text("Positions use a percentage of canvas height. Positive vertical values move the picture up. Graphics remain separate layers; captions move into the portrait safe area.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                graphicControls
                ClautoToggle(title: "Process dialogue audio in this export", isOn: $audioEnabled)
                if audioEnabled {
                    HStack { Text("Gain \(audio.gainDB, specifier: "%.1f") dB"); ClautoSlider(value: $audio.gainDB, range: -30...12, label: "Dialogue gain") }
                    ClautoToggle(title: "Reduce low rumble (80Hz high-pass)", isOn: $highpass)
                    ClautoToggle(title: "Compress loud peaks", isOn: $audio.compressor)
                    ClautoToggle(title: "Add short echo (120ms)", isOn: $echo)
                    Text("Effects stay in separate local audio files in the editable handoff. Delayed tails outside the selected interval are trimmed; the interval is not retimed.")
                        .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                }
                ClautoChoice(title: "Optional local sound effect", selection: $request.soundFileID, options: [(Optional<UUID>.none, "None")] + project.manifest.files.filter { [.audio, .music].contains($0.group) }.map { (Optional($0.id), $0.name) })
                if request.soundFileID != nil {
                    HStack {
                        ClautoNumberField(label: "Sound time in export (seconds)", value: $request.soundAt)
                        ClautoNumberField(label: "Sound gain (dB)", value: $request.soundGainDB)
                    }
                    Text("The sound starts at that time and stops at its own end or the export boundary. Original audio stays separate in the handoff.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                }
                if request.resolution == .ultraHD { Text("4K can enlarge smaller sources without adding detail. Review the resulting picture.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
                HStack {
                    ClautoAction("Create local export", icon: .export, kind: .primary) {
                        let endText = end.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let at = Double(start), endText.isEmpty || Double(endText) != nil else { store.notice = "Enter export times in seconds."; return }
                        var captured = request
                        captured.start = at; captured.end = endText.isEmpty ? nil : Double(endText)
                        var effects = audio
                        effects.highpassHZ = highpass ? 80 : nil; effects.echoDelayMS = echo ? 120 : nil
                        captured.effects = audioEnabled ? effects : nil
                        let capturedVersion = version, capturedProject = project
                        Task { await store.exportDerivative(captured, version: capturedVersion, project: capturedProject) }
                    }.disabled(store.exportingDerivativeProjectID != nil || store.runningProjectID != nil)
                        .accessibilityIdentifier("createDerivative")
                    if store.exportingDerivativeProjectID == project.id {
                        ClautoActivity(label: "Exporting locally…")
                        Button("Stop Export") { Task { await store.cancelDerivative() } }
                    }
                }
                let exports = (store.derivedCuts[project.id] ?? []).filter { $0.parentVersionID == version.id }
                if !exports.isEmpty {
                    ClautoChoice(title: "Verified exports", selection: $selectedExport, options: [(Optional<UUID>.none, "Choose an export")] + exports.map { (Optional($0.id), "\($0.request.aspect) · \($0.request.resolution.rawValue) · \($0.created.formatted())") })
                    if let item = exports.first(where: { $0.id == selectedExport }) ?? exports.first {
                        let folder = project.folder.appendingPathComponent("build/derivatives/" + item.id.uuidString)
                        ClautoVideoViewer(url: folder.appendingPathComponent("review.mp4")).frame(minHeight: 270).id(item.id)
                        HStack {
                            Button("Reveal Verified Export") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            Button("Reveal Editable Timeline") { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("timeline.fcpxml")]) }
                        }
                        Text("Full decode and output hashes verified. Review framing, captions and sound before sharing.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    }
                }
                ClautoDisclosure("Export details") { Text(store.derivativeDetails[project.id] ?? "No export has run.").font(ClautoDesign.caption.monospacedDigit()).textSelection(.enabled) }
            }.padding(.vertical, 8)
        }
        .onAppear { request.resolution = version.exportResolution ?? project.manifest.outputResolution }
        .task(id: project.id.uuidString+version.id.uuidString) { await loadGraphicChoices() }
        .onChange(of: store.graphicStudios[project.id]?.exported?.revision.id) { _,_ in Task { await loadGraphicChoices() } }
    }
    private var graphicControls: some View {
        VStack(alignment: .leading,spacing: 8) {
            let selected = request.graphic
            let menu = [(Optional<UUID>.none,"None")]+graphicChoices.map { (Optional($0.id),$0.label+" · exported revision") }
            let options = selected.map { value in menu.contains(where: { $0.0==value.revisionID }) ? menu:menu+[(Optional(value.revisionID),"Earlier selected graphic revision")] } ?? menu
            ClautoChoice(title: "Graphic from this project",selection: Binding(get: { request.graphic?.revisionID },set: { id in
                guard let id else { request.graphic = nil;return }
                guard let choice = graphicChoices.first(where: { $0.id==id }) else { return }
                var value = choice.selection
                if let total = savedDuration {
                    let lower = Double(start) ?? 0,upper = Double(end) ?? total
                    if upper>lower { value.duration = min(value.duration,DerivativeRequest.snapped(upper)-DerivativeRequest.snapped(lower)) }
                }
                request.graphic = value
            }),options: options)
            HStack {
                Button("Refresh exported graphics") { Task { await loadGraphicChoices() } }.disabled(graphicLoading)
                if graphicLoading { ClautoActivity(label: "Loading exported graphics…") }
            }
            if let graphicError { Text(graphicError).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
            if let selected {
                HStack {
                    ClautoNumberField(label: "Graphic start in export (seconds)",value: graphicBinding(\.at,selected))
                    ClautoNumberField(label: "Start within graphic (seconds)",value: graphicBinding(\.sourceStart,selected))
                    ClautoNumberField(label: "Graphic duration (seconds)",value: graphicBinding(\.duration,selected))
                }
                HStack {
                    ClautoNumberField(label: "Graphic scale",value: graphicBinding(\.scale,selected))
                    ClautoNumberField(label: "Graphic horizontal position %",value: graphicBinding(\.x,selected))
                    ClautoNumberField(label: "Graphic vertical position %",value: graphicBinding(\.y,selected))
                }
                Text("The exported graphic keeps its cutouts, font and model inputs. Timing and placement stay editable in the separate timeline; changing a scene later creates another graphic revision.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            } else {
                Text("Export a scene in Studio → Graphics, then choose it here. Its transparent movie is placed over this saved cut and checked before composition.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            }
        }
    }
    private func graphicBinding(_ key: WritableKeyPath<GraphicCutSelection,Double>,_ selected: GraphicCutSelection) -> Binding<Double> {
        Binding(get: { request.graphic?[keyPath: key] ?? 0 },set: { value in
            guard request.graphic?.revisionID==selected.revisionID,request.graphic?.manifestSHA256==selected.manifestSHA256 else { return }
            request.graphic?[keyPath: key] = value
        })
    }
    @MainActor private func loadGraphicChoices() async {
        let token = UUID();graphicLoadID = token;graphicLoading = true;graphicError = nil
        defer { if graphicLoadID==token { graphicLoading = false } }
        do {
            let source = try await WorkflowRepository().derivativeSource(version,project: project)
            let values = try await GraphicStudioRepository().exportedChoices(project)
            try Task.checkCancellation();guard graphicLoadID==token else { return }
            savedDuration = source.duration;graphicChoices = values
            if let selected = request.graphic,selected.projectID != project.id { request.graphic = nil }
        } catch is CancellationError {} catch { if graphicLoadID==token { graphicError = error.localizedDescription } }
    }

}
