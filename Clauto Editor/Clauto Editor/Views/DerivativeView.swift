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
    }
}
