import SwiftUI
import AVKit

struct DerivativeView: View {
    @Bindable var store: EditorStore
    var project: Project
    var version: CutVersion
    @State private var request = DerivativeRequest()
    @State private var start = "0"
    @State private var end = ""
    @State private var audioEnabled = false
    @State private var audio = LocalAudioEffects()
    @State private var highpass = false
    @State private var echo = false
    @State private var selectedExport: UUID?
    var body: some View {
        DisclosureGroup("Export this saved version / make a vertical cut") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Creates a separate, verified export and editable timeline from v\(version.number). The saved parent stays available.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Output", selection: $request.aspect) { Text("9:16 · portrait").tag("9:16"); Text("16:9 · landscape").tag("16:9") }
                    Picker("Resolution", selection: $request.resolution) { ForEach(ExportResolution.allCases) { Text($0.label).tag($0) } }
                }
                HStack {
                    TextField("Start seconds", text: $start).accessibilityIdentifier("derivativeStart")
                    TextField("End seconds (blank = end of cut)", text: $end).accessibilityIdentifier("derivativeEnd")
                }
                Picker("Picture framing", selection: $request.framing) { Text("Fit entire picture").tag("fit"); Text("Fill canvas / crop").tag("fill") }
                HStack {
                    TextField("Horizontal position %", value: $request.x, format: .number)
                    TextField("Vertical position %", value: $request.y, format: .number)
                }
                Text("Positions use a percentage of canvas height. Positive vertical values move the picture up. Graphics remain separate layers; captions move into the portrait safe area.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Process dialogue audio in this export", isOn: $audioEnabled)
                if audioEnabled {
                    HStack { Text("Gain \(audio.gainDB, specifier: "%.1f") dB"); Slider(value: $audio.gainDB, in: -30...12).accessibilityLabel("Dialogue gain") }
                    Toggle("Reduce low rumble (80Hz high-pass)", isOn: $highpass)
                    Toggle("Compress loud peaks", isOn: $audio.compressor)
                    Toggle("Add short echo (120ms)", isOn: $echo)
                    Text("Effects stay in separate local audio files in the editable handoff. Delayed tails outside the selected interval are trimmed; the interval is not retimed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Optional local sound effect", selection: $request.soundFileID) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(project.manifest.files.filter { [.audio, .music].contains($0.group) }) { file in Text(file.name).tag(Optional(file.id)) }
                }
                if request.soundFileID != nil {
                    HStack {
                        TextField("Sound time in export (seconds)", value: $request.soundAt, format: .number)
                        TextField("Sound gain (dB)", value: $request.soundGainDB, format: .number)
                    }
                    Text("The sound starts at that time and stops at its own end or the export boundary. Original audio stays separate in the handoff.").font(.caption).foregroundStyle(.secondary)
                }
                if request.resolution == .ultraHD { Text("4K can enlarge smaller sources without adding detail. Review the resulting picture.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Create Local Export", systemImage: "square.and.arrow.up") {
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
                        ProgressView().controlSize(.small)
                        Button("Stop Export") { Task { await store.cancelDerivative() } }
                    }
                }
                let exports = (store.derivedCuts[project.id] ?? []).filter { $0.parentVersionID == version.id }
                if !exports.isEmpty {
                    Picker("Verified exports", selection: $selectedExport) {
                        Text("Choose an export").tag(Optional<UUID>.none)
                        ForEach(exports) { item in Text("\(item.request.aspect) · \(item.request.resolution.rawValue) · \(item.created.formatted())").tag(Optional(item.id)) }
                    }
                    if let item = exports.first(where: { $0.id == selectedExport }) ?? exports.first {
                        let folder = project.folder.appendingPathComponent("build/derivatives/" + item.id.uuidString)
                        DerivativePreview(url: folder.appendingPathComponent("review.mp4")).frame(height: 240).id(item.id)
                        HStack {
                            Button("Reveal Verified Export") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            Button("Reveal Editable Timeline") { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("timeline.fcpxml")]) }
                        }
                        Text("Full decode and output hashes verified. Review framing, captions and sound before sharing.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Export details") { Text(store.derivativeDetails[project.id] ?? "No export has run.").font(.caption.monospaced()).textSelection(.enabled) }
            }.padding(.vertical, 8)
        }
        .onAppear { request.resolution = version.exportResolution ?? project.manifest.outputResolution }
    }
}

private struct DerivativePreview: NSViewRepresentable {
    var url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline; view.player = AVPlayer(url: url); return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url { view.player?.pause(); view.player = AVPlayer(url: url) }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
