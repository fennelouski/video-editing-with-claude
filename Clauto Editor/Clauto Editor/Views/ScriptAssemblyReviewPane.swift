import SwiftUI
import AppKit

/// Lives in the existing Cut workspace. An editable assembly is deliberately not
/// presented as an already rendered saved cut or an authorization to publish.
struct ScriptAssemblyReviewPane: View {
    let assembly: ScriptAssemblyReview
    let project: Project
    let openScript: () -> Void
    let openStudio: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(assembly.record.title).font(ClautoDesign.heading).accessibilityAddTraits(.isHeader)
                Text(assembly.readyForReview ? "Approved script revision · source-linked assembly candidate" : "Historical assembly · script approval or source verification needs review")
                    .font(ClautoDesign.caption).foregroundStyle(assembly.readyForReview ? ClautoDesign.quiet : ClautoDesign.ember)
                Text("This candidate belongs to \(project.manifest.name). It does not replace the current cut. The timeline references original media; it has no rendered preview yet.")
                    .font(ClautoDesign.caption).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
                Text("Sound editing is available for rendered saved cuts. Studio's existing graphics, 3D scenes and handwriting/font tools keep using this same project and its external asset references.")
                    .font(ClautoDesign.caption).fixedSize(horizontal: false, vertical: true)
                ClautoRule()
                Text("Ordered source timeline · 24000/1001 fps").font(ClautoDesign.type(16, weight: .semibold)).accessibilityAddTraits(.isHeader)
                ForEach(assembly.handoff.spans, id: \.id) { span in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(ReviewTimecode.label(frame: span.timelineFrame)) · \(span.sourceID)").font(ClautoDesign.type(15, weight: .semibold))
                        Text("Source \(ReviewTimecode.label(frame: span.startFrame))–\(ReviewTimecode.label(frame: span.endFrame)) · \(span.frames) frames")
                            .font(ClautoDesign.caption)
                        Text("Source SHA-256: \(span.sourceSHA256)").font(ClautoDesign.caption).textSelection(.enabled)
                        if let source = assembly.handoff.sources.first(where: { $0.id == span.id }) {
                            Text("Words \(source.firstWord)…\(source.lastWord) · \(source.sourcePath)").font(ClautoDesign.caption).textSelection(.enabled)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(ClautoDesign.sheet).accessibilityElement(children: .contain)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.visible).font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink)
            .buttonStyle(ClautoButtonStyle()).accessibilityIdentifier("scriptAssemblyCutReview")
    }
    @ViewBuilder private var actions: some View {
        Button("Return to source script") { openScript() }.accessibilityIdentifier("assemblyReturnToScript")
        Button("Open project Studio") { openStudio() }.accessibilityIdentifier("assemblyOpenStudio")
        Button("Show editable FCPXML") {
            NSWorkspace.shared.activateFileViewerSelecting([project.folder.appendingPathComponent(assembly.record.relativeFolder).appendingPathComponent("assembly.fcpxml")])
        }
    }
}
