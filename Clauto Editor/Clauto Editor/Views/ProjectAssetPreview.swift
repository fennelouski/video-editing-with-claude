import SwiftUI
import QuickLookUI

struct ProjectAssetPreview: Identifiable {
    var id: UUID
    var title: String
    var url: URL
}
struct ProjectAssetPreviewView: View {
    let item: ProjectAssetPreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.title).font(.headline).lineLimit(2)
                Spacer()
                Button { dismiss() } label: { Label("Close preview",systemImage: "xmark") }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("closeAssetPreview")
            }.padding(18)
            Divider()
            NativeProjectAssetPreview(url: item.url)
        }.frame(minWidth: 760,minHeight: 560)
    }
}

/// Passive original-rate playback only. It never registers a frame-feedback
/// target, approves an edit, generates media or autostarts audio.
struct ProjectMovieSourcePreview: View {
    let item: ProjectAssetPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.headline).textSelection(.enabled)
            Text("Source movie preview. Timeline editing and frame feedback become available with a saved cut. The movie keeps its original timing and audio.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            NativeProjectAssetPreview(url: item.url).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(18).accessibilityIdentifier("projectMoviePreview")
    }
}
private struct NativeProjectAssetPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero,style: .normal)!;view.autostarts = false;return view
    }
    func updateNSView(_ view: QLPreviewView,context: Context) {
        view.autostarts = false
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView,coordinator: ()) { view.close() }
}
