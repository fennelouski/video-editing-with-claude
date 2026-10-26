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
