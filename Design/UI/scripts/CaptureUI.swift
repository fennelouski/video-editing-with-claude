// Synthetic native UI verification. No foreground windows, private files, or live actions.
import SwiftUI
import AppKit
import CoreText
import Observation
import AVFoundation

@MainActor @Observable final class CaptureControlState {
    var field = "A synthetic project title"
    var notes = "This is synthetic text for checking native editing, selection, and wrapping. The interface must keep text readable as the window changes size. No user project or media is loaded."
    var amount = 1.25
    var choice = "medium"
    var enabled = false
    var slider = 0.4
    var presses = 0
}

struct ControlGallery: View {
    @Bindable var state: CaptureControlState
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Clauto control states").font(ClautoDesign.heading)
            Text("Synthetic fixture · buttons, editable text, choices, checkboxes, and an adjustable playhead")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            ClautoSection("Actions") {
                HStack(spacing: 12) {
                    ClautoAction("Primary action", icon: .check, kind: .primary) { state.presses += 1 }.accessibilityIdentifier("capturePrimary")
                    ClautoAction("Secondary", icon: .folder) {}
                    ClautoAction("Quiet action", icon: .arrow, kind: .quiet) {}
                    ClautoAction("Remove", icon: .close, kind: .danger) {}
                    ClautoAction("Unavailable", icon: .export, kind: .primary) {}.disabled(true)
                }
            }
            ClautoRule()
            HStack(alignment: .top, spacing: 20) {
                ClautoField(label: "Project title", text: $state.field)
                ClautoNumberField(label: "Position", value: $state.amount).frame(width: 150)
            }
            ClautoTextArea(text: $state.notes, label: "Synthetic notes").frame(height: 120)
            HStack(alignment: .top, spacing: 24) {
                ClautoChoice(title: "Speech model", selection: $state.choice, options: [("small", "Fast · small"), ("medium", "Balanced · medium"), ("large", "Best · large")], expandedByDefault: true)
                VStack(alignment: .leading, spacing: 18) {
                    ClautoToggle(title: "Synthetic audio processing", isOn: $state.enabled)
                    ClautoToggle(title: "Unavailable option", isOn: .constant(false)).disabled(true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ClautoSection("Playhead") {
                ClautoSlider(value: $state.slider, range: 0...1, label: "Synthetic playhead")
                Text(String(format: "Value %.2f", state.slider)).font(ClautoDesign.caption.monospacedDigit())
            }
            ClautoActivity(label: "Working locally…")
            Text("Needs attention: this is a deliberately visible synthetic error state.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember)
            Spacer(minLength: 0)
        }.padding(32).font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink)
            .background(ClautoDesign.paper).buttonStyle(ClautoButtonStyle()).preferredColorScheme(.light)
    }
}

@main struct CaptureUI {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Design/UI/previews/round-1", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let font = repo.appendingPathComponent("assets/fonts/WorkSans[wght].ttf")
        var fontError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(font as CFURL, .process, &fontError), NSFont(name: "WorkSans-Regular", size: 14) != nil else {
            throw CaptureFailure.failed("The existing OFL Work Sans font did not register")
        }
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("clauto-ui-synthetic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "clauto.ui.synthetic." + UUID().uuidString)!
        let store = EditorStore(defaults: defaults)
        store.projectRoot = fixture
        store.engineRoot = fixture.appendingPathComponent("Synthetic engine")
        let project = try makeProject(in: fixture)
        store.projects = [project]
        store.selectedID = project.id
        try await makeSavedCut(project: project)
        await store.loadWorkflow()
        var evidence: [[String: Any]] = []
        let transcript = store.transcriptReview(for: project)
        let catalog = try makeTranscriptCatalog(project: project)
        let transcriptURL = fixture.appendingPathComponent("synthetic-transcript.json")
        try JSONEncoder().encode(catalog).write(to: transcriptURL)
        await transcript.importCatalog(transcriptURL)
        guard transcript.session != nil, transcript.failure == nil else { throw CaptureFailure.failed("Synthetic transcript import failed") }
        evidence.append(try await capture(ContentView(store: store, initialProjectTab: "Transcript"), name: "transcript-project-wide", width: 1440, height: 900, output: output))
        evidence.append(try await capture(ContentView(store: store, initialProjectTab: "Transcript"), name: "transcript-project-minimum", width: 900, height: 640, output: output))
        evidence.append(try await capture(TranscriptWorkspace(controller: transcript, initialSelectedID: catalog.rows[0].id), name: "transcript-inspector-wide", width: 1100, height: 860, output: output))
        evidence.append(try await capture(TranscriptWorkspace(controller: transcript, initialSelectedID: catalog.rows[0].id), name: "transcript-inspector-minimum", width: 630, height: 640, output: output))
        for (name, width, height, tab) in [
            ("brief-wide", 1440, 900, "Brief"),
            ("brief-minimum", 900, 640, "Brief"),
            ("files-minimum", 900, 640, "Files"),
            ("cut-wide", 1320, 860, "Cut"),
            ("cut-minimum", 900, 640, "Cut")
        ] {
            evidence.append(try await capture(ContentView(store: store, initialProjectTab: tab), name: name,
                                              width: width, height: height, output: output))
        }
        store.notice = "A synthetic drive is unavailable. Reconnect it and choose the original project folder.\n\n" + String(repeating: "Synthetic tool detail: the requested reference path is unavailable; verify the local folder and retry. This message is intentionally long to check that the workspace remains usable.\n", count: 10)
        evidence.append(try await capture(ContentView(store: store), name: "notice-minimum", width: 900, height: 640, output: output))
        store.notice = nil
        if let version = store.currentCuts[project.id] {
            let unavailable = project.folder.appendingPathComponent("cuts/\(version.folderName)/exports/synthetic.preview.mp4")
            let review = ScrollView { VersionReview(store: store, project: project, version: version, url: unavailable).padding(28) }
                .font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).background(ClautoDesign.paper).buttonStyle(ClautoButtonStyle()).scrollIndicators(.hidden)
            evidence.append(try await capture(review, name: "saved-review-feedback", width: 900, height: 1000, output: output))
            let derivative = ScrollView { DerivativeView(store: store, project: project, version: version, expandedByDefault: true).padding(28) }
                .font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink).background(ClautoDesign.paper).buttonStyle(ClautoButtonStyle()).scrollIndicators(.hidden)
            evidence.append(try await capture(derivative, name: "derivative-expanded", width: 900, height: 900, output: output))
        }
        var longProject = project
        longProject.manifest.name = "A synthetic project with a deliberately long title about the complete comparison, the narration, and the final result"
        longProject.brief.about += "\n\n" + String(repeating: "A long synthetic brief keeps its details in the editable document and must wrap without changing the rail or the composer. ", count: 5)
        store.projects = [longProject]
        let longRequest = LocalMessage(text: String(repeating: "A deliberately long synthetic request names the change, its reason, and the moment that needs review. ", count: 6))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([longRequest]).write(to: project.folder.appendingPathComponent("notes/conversation.json"))
        await store.loadWorkflow()
        evidence.append(try await capture(ContentView(store: store), name: "long-content-minimum", width: 900, height: 640, output: output))
        store.projects = [project]
        store.setupChecks = [
            SetupCheck(id: "folders", title: "Project folder", state: .ready, detail: "Synthetic fixture folder is available."),
            SetupCheck(id: "tools", title: "Video tools", state: .ready, detail: "Synthetic status for the local workspace view."),
            SetupCheck(id: "model", title: "Speech model", state: .needsAttention, detail: "Choose a local model cache before starting a cut."),
            SetupCheck(id: "claude", title: "Claude session", state: .notChecked, detail: "Live Claude calls are disabled in this build.")
        ]
        evidence.append(try await capture(SetupView(store: store), name: "workspace", width: 680, height: 680, output: output))
        store.selectedID = nil
        evidence.append(try await capture(ContentView(store: store), name: "empty-minimum", width: 900, height: 640, output: output))
        let controls = CaptureControlState()
        let (host, window) = makeHost(ControlGallery(state: controls), width: 940, height: 1000)
        await settle(host)
        try write(host, to: output.appendingPathComponent("controls-expanded.png"))
        var checks: [String: Any] = [
            "accessibility_actions": "unavailable in this offscreen/prohibited host; no actions asserted",
            "choice_expansion": "rendered from the control's initial state",
            "physical_hover_keyboard_voiceover": "not run"
        ]
        if let textView = descendants(host).compactMap({ $0 as? NSTextView }).first {
            checks["native_text_font"] = textView.font?.fontName ?? "unavailable"
            let addition = "\nA synthetic editing check."
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.insertText(addition, replacementRange: textView.selectedRange())
            await settle(host)
            checks["native_text_binding"] = controls.notes.hasSuffix(addition)
            checks["native_undo_manager"] = textView.undoManager != nil
        } else { checks["native_text_binding"] = "unavailable" }
        controls.choice = "large"; controls.enabled = true; controls.slider = 0.57
        await settle(host)
        try write(host, to: output.appendingPathComponent("controls-values-updated.png"))
        evidence.append(["name": "controls", "points": [940, 1000], "pixels": [940, 1000], "checks": checks,
                         "accessibility": describe(accessibilityNodes(host))])
        window.close()
        evidence.append(try await capture(ClautoVideoViewer(url: fixture.appendingPathComponent("Unavailable synthetic preview.mp4")), name: "unavailable-preview", width: 680, height: 480, output: output))
        let report: [String: Any] = ["fixture": "synthetic only", "activation_policy": "prohibited", "window_visibility": "never ordered onscreen", "valid_video_playback": "not exercised; host denied synthetic video encoding",
                                     "captures": evidence, "font": NSFont(name: "WorkSans-Regular", size: 14)?.fontName ?? "unavailable",
                                     "limits": ["Offscreen captures do not verify physical hover, drag delivery, foreground keyboard traversal, VoiceOver speech, or AVPlayer hardware video layers."]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("verification.json"))
        print("Synthetic capture batch complete: \(output.path)")
        print("Native control evidence: \(checks)")
    }

    @MainActor static func makeHost<Content: View>(_ content: Content, width: Int, height: Int) -> (NSHostingView<AnyView>, NSWindow) {
        let rectangle = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: rectangle, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(content.frame(width: CGFloat(width), height: CGFloat(height))))
        host.frame = rectangle
        window.contentView = host
        // Deliberately do not call orderFront, makeKey, activate, open, or NSApp.run.
        return (host, window)
    }
    @MainActor static func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    @MainActor static func capture<Content: View>(_ content: Content, name: String, width: Int, height: Int, output: URL) async throws -> [String: Any] {
        let (host, window) = makeHost(content, width: width, height: height)
        await settle(host)
        let pixels = try write(host, to: output.appendingPathComponent(name + ".png"))
        let entries = describe(accessibilityNodes(host))
        window.close()
        return ["name": name, "points": [width, height], "pixels": pixels, "accessibility": entries]
    }
    @discardableResult @MainActor static func write(_ view: NSView, to file: URL) throws -> [Int] {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureFailure.failed("No bitmap context") }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { throw CaptureFailure.failed("No PNG representation") }
        try png.write(to: file)
        return [image.pixelsWide, image.pixelsHigh]
    }
    @MainActor static func accessibilityNodes(_ root: Any) -> [any NSAccessibilityProtocol] {
        var output: [any NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ item: Any) {
            guard let node = item as? any NSAccessibilityProtocol else { return }
            let identifier = ObjectIdentifier(node)
            guard visited.insert(identifier).inserted else { return }
            output.append(node)
            for child in node.accessibilityChildren() ?? [] { visit(child) }
        }
        visit(root)
        return output
    }
    @MainActor static func describe(_ nodes: [any NSAccessibilityProtocol]) -> [[String: String]] {
        nodes.compactMap { node in
            let label = node.accessibilityLabel() ?? ""
            let role = node.accessibilityRole()?.rawValue ?? ""
            guard !label.isEmpty || ["AXTextField", "AXTextArea", "AXSlider", "AXCheckBox"].contains(role) else { return nil }
            return ["role": role, "label": label, "value": String(describing: node.accessibilityValue() ?? ""),
                    "enabled": String(node.isAccessibilityEnabled())]
        }
    }
    @MainActor static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }
    static func makeSavedCut(project: Project) async throws {
        let folder = project.folder.appendingPathComponent("cuts/v001/exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // This host denies synthetic video encoding. Use an explicit metadata-only
        // saved cut and exercise missing-preview recovery in a separate capture.
        var version = CutVersion(number: 1, label: "Synthetic saved cut", engineVersion: "synthetic", runID: UUID(), artifacts: ["exports/synthetic.preview.mp4"], approvedPlanHash: "synthetic")
        version.exportResolution = .fullHD; version.aspect = "16:9"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(version).write(to: folder.deletingLastPathComponent().appendingPathComponent("clauto-version.json"))
        try encoder.encode(version.id).write(to: project.folder.appendingPathComponent("cuts/current.json"))
    }
    static func makeProject(in root: URL) throws -> Project {
        let folder = root.appendingPathComponent("The table experiment — synthetic", isDirectory: true)
        let fm = FileManager.default
        for name in ["notes", "cuts", "build/runs", "footage/a-cam", "footage/audio", "assets/music", "script", ".clauto"] {
            try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var brief = Brief()
        brief.about = "A synthetic project about comparing two everyday methods. Begin with the result, then explain the steps and show the difference. This fixture checks layout and editing controls; it is not a scientific or editorial claim."
        brief.audience = "Curious home cooks"
        brief.length = "About five minutes"
        brief.tone = "Clear, curious, and conversational"
        brief.music = "A quiet recorded acoustic bed"
        brief.graphics = "Use supplied captions and a simple comparison label"
        brief.script = "[Synthetic annotated script]\nOpening: show the two results.\nDemonstration: explain the steps.\nClose: recap the visible difference."
        var manifest = ProjectManifest(name: "The table experiment — synthetic", engineVersion: "synthetic")
        for (name, group) in [("Complete narration take.mov", FileGroup.footage), ("Room recording.wav", .audio), ("A quiet acoustic bed.wav", .music), ("Annotated script.md", .scripts)] {
            let relative = group.folder + "/" + name
            let path = folder.appendingPathComponent(relative)
            try Data("Synthetic UI placeholder; not playable source media.".utf8).write(to: path)
            manifest.files.append(ProjectFile(name: name, group: group, relativePath: relative, originalPath: path.path, copied: false, needsRole: false))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("clauto-project.json"))
        try Data(brief.markdown.utf8).write(to: folder.appendingPathComponent("brief.md"))
        let messages = [LocalMessage(text: "Keep the opening concise, then let the complete demonstration breathe."), LocalMessage(text: "Use the supplied comparison label when the second result appears.")]
        try encoder.encode(messages).write(to: folder.appendingPathComponent("notes/conversation.json"))
        return Project(manifest: manifest, folder: folder, brief: brief)
    }

    static func makeTranscriptCatalog(project: Project) throws -> TranscriptCatalog {
        let sentences = ["Begin with the result on the table.", "This is the first complete synthetic take.",
                         "Now compare the second result with it.", "Keep the explanation connected to this action.",
                         "Pause briefly before showing the next step.", "Close by returning to the opening question."]
        var words: [TranscriptWord] = [], rows: [TranscriptRow] = []
        let sourceSHA = String(repeating: "a", count: 64), sourceID = "Synthetic_Canon_01"
        for (index, sentence) in sentences.enumerated() {
            let first = words.count
            for (offset, word) in sentence.split(separator: " ").enumerated() {
                let start = Double(index) * 4 + Double(offset) * 0.3 + 0.1
                words.append(.init(word: String(word), start: start, end: start + 0.2))
            }
            let last = words.count - 1
            rows.append(.init(id: sourceID + String(format: "-w%05d-%05d-", first, last) + sourceSHA.prefix(8),
                sourceID: sourceID, sourceSHA256: sourceSHA, firstWord: first, lastWord: last,
                start: words[first].start, end: words[last].end,
                inTimecode: String(format: "00:00:%02d:02", index * 4), outTimecode: String(format: "00:00:%02d:08", index * 4 + 2),
                text: sentence, keep: index != 1, notes: index == 0 ? "Synthetic comment: keep the opening concise." : "",
                requestedGraphics: index == 0 ? "Synthetic request: a comparison title." : "",
                assistantGraphics: "Optional paper comparison diagram. This is a suggestion, not an approved graphic.",
                handwrittenAsset: "", section: "Synthetic main shoot", uncertainty: "Synthetic ASR; listening acceptance not asserted.", originalOrder: index + 1))
        }
        return .init(schemaVersion: 1, title: "Synthetic transcript review", datasetSHA256: String(repeating: "e", count: 64),
            sources: [.init(id: sourceID, path: project.folder.appendingPathComponent("footage/a-cam/Complete narration take.mov").path,
                            sourceSHA256: sourceSHA, transcriptSHA256: String(repeating: "c", count: 64), duration: 30, words: words)], rows: rows)
    }
}

enum CaptureFailure: Error { case failed(String) }
