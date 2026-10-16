import SwiftUI
import CoreText

struct FontRevisionView: View {
    @Bindable var controller: FontStudioController
    let fontID: UUID
    let currentRevision: UUID
    @State private var revisions: [FontExportRevision] = []
    @State private var selected: UUID?
    @State private var text = ""
    @State private var font: CTFont?
    @State private var ttfURL: URL?
    @State private var woffURL: URL?
    @State private var issue: String?
    @State private var layout: FontPreviewLayout?
    var body: some View {
        ClautoSection("Saved font revisions",detail: "Preview the actual compiled font without installing it on this Mac. Choose an earlier revision to inspect its unchanged files.") {
            if !revisions.isEmpty {
                ClautoChoice(title: "Revision",selection: Binding(get: { selected ?? currentRevision },set: { selected = $0 }),options: revisions.map { ($0.id,"\($0.family) · \($0.id.uuidString.prefix(8))") })
            }
            ClautoField(label: "Preview text",text: $text,placeholder: "Type mapped characters")
            if let layout {
                ScrollView([.horizontal,.vertical]) {
                    Canvas { context,_ in for path in layout.paths { context.fill(Path(path),with: .color(ClautoDesign.ink)) } }
                        .frame(width: layout.width,height: max(100,layout.height)).padding(12)
                        .accessibilityLabel("Actual custom font outline preview. "+(layout.missing.isEmpty ? "All characters are mapped.":"Missing: "+layout.missing.joined(separator: ", ")))
                }.frame(height: min(320,max(120,layout.height+24))).background(ClautoDesign.soft)
                if !layout.missing.isEmpty { Text("Missing characters: "+layout.missing.joined(separator: " ")).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
            }
            Text("Unmapped characters appear as missing glyphs. Add a supplied or clearly labelled generated character above, then rebuild.").font(ClautoDesign.caption)
            HStack {
                if let ttfURL { ClautoAction("Show TTF",icon: .folder) { NSWorkspace.shared.activateFileViewerSelecting([ttfURL]) } }
                if let woffURL { ClautoAction("Show WOFF2",icon: .folder) { NSWorkspace.shared.activateFileViewerSelecting([woffURL]) } }
            }
            if let issue { Text(issue).foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption) }
        }.task {
            do { revisions = try await controller.repository.revisions(controller.project,fontID: fontID);text = controller.draft?.glyphs.map(\.character).joined() ?? "";selected = currentRevision }
            catch { issue = error.localizedDescription }
        }.task(id: selected) {
            font = nil;layout = nil;ttfURL = nil;woffURL = nil;issue = nil
            guard let selected else { return }
            do {
                let result = try await controller.repository.fontBytes(controller.project,fontID: fontID,revisionID: selected)
                try Task.checkCancellation()
                guard let provider = CGDataProvider(data: result.bytes as CFData),let parsed = CGFont(provider) else { throw ProjectFailure.invalidProject }
                font = CTFontCreateWithGraphicsFont(parsed,48,nil,nil);refreshPreview();ttfURL = result.ttfURL;woffURL = result.woff2URL
            } catch is CancellationError {} catch { issue = error.localizedDescription }
        }.onChange(of: text) { refreshPreview() }
    }
    private func refreshPreview() {
        guard let font else { layout = nil;return }
        do { layout = try FontPreviewGeometry.layout(text,font: font,width: 600);issue = nil }
        catch { layout = nil;issue = error.localizedDescription }
    }
}
