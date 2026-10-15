import SwiftUI

struct EditorCommandPalette: View {
    let router: ReviewWindowRouter
    @State private var query = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack {
                TextField("Find a command",text: $query).textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityIdentifier("commandPaletteQuery")
                Button("Close") { router.paletteVisible = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(EditorCommand.allCases.filter { $0 != .palette && $0.matches(query) }) { command in
                        Button { router.choosePaletteCommand(command) } label: {
                            HStack { Text(command.title); Spacer(); Text(command.shortcut).font(.caption).foregroundStyle(.secondary) }
                                .padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(command.needsPlayer && router.selected?.ready != true)
                            .accessibilityIdentifier("command-\(command.rawValue)")
                    }
                }
            }
        }.padding(20).frame(width: 580,height: 500).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink)
            .onAppear { focused = true }
    }
}
struct ReviewTimecodeEntry: View {
    let router: ReviewWindowRouter
    @State private var text = ""
    @State private var error: String?
    @State private var endpointID: UUID?
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("Go to timecode").font(.title2)
            TextField("HH:MM:SS:FF",text: $text).monospacedDigit().textFieldStyle(.roundedBorder)
            Text("23.976 fps · 24-frame non-drop").font(.caption).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(ClautoDesign.ember).textSelection(.enabled) }
            HStack {
                Button("Cancel") { router.showTimecode = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Go") {
                    do {
                        guard let endpoint = router.selected, endpoint.id == endpointID, endpoint.ready else { throw WorkflowFailure.invalid("The selected player changed. Reopen Go to Timecode.") }
                        let frame = try ReviewTimecode.frame(text), seconds = ReviewTimecode.seconds(frame: frame)
                        guard seconds < endpoint.target.duration else { throw WorkflowFailure.invalid("Timecode is past this version's last frame.") }
                        endpoint.driver.pause(); endpoint.driver.seek(seconds: seconds); router.showTimecode = false
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420).background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink)
            .onAppear { endpointID = router.selectedID; if let clock = router.selected?.driver.clock { text = ReviewTimecode.label(frame: Int(Double(clock.value)/Double(clock.timescale)*24000/1001)) } }
    }
}
