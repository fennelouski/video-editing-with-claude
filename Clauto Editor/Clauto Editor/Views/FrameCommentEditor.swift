import SwiftUI
import AppKit

struct FrameCommentEditor: View {
    @Bindable var controller: FrameCommentController
    let close: () -> Void
    @State private var x = "0.25"
    @State private var y = "0.25"
    @State private var width = "0.25"
    @State private var height = "0.25"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment on a paused frame").font(ClautoDesign.heading).accessibilityAddTraits(.isHeader)
            if let draft = controller.draft {
                Text(String(format: "Version %d · Frame %d · %.6f seconds", draft.request.target.versionNumber,draft.request.frame.frameIndex,draft.request.frame.seconds))
                    .font(ClautoDesign.caption.monospacedDigit()).textSelection(.enabled)
                if let frame = draft.frame {
                    FrameAnnotationCanvas(draft: draft, enabled: !controller.saving).frame(minHeight: 220,maxHeight: 380)
                        .accessibilityLabel("Paused frame annotation canvas. Drag inside the video to draw. Coordinate fields below also add marks.")
                    annotationControls(draft,frame: frame).disabled(controller.saving)
                } else { ClautoActivity(label: controller.preparing ? "Capturing and verifying the exact local frame…" : "The paused frame is unavailable. Cancel and try again.") }
                TextField("Comment on this frame",text: Binding(get: { draft.text },set: { if !controller.saving { draft.text = $0 } }),axis: .vertical)
                    .lineLimit(3...5).textFieldStyle(.roundedBorder).disabled(controller.saving).accessibilityIdentifier("frameCommentText")
                Text("Marks describe this saved frame. Add a written instruction; a circle does not approve a cut or change the video.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                if let error = controller.error { Text(error).foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { if controller.cancel() { close() } }.keyboardShortcut(.cancelAction).disabled(controller.saving).accessibilityIdentifier("cancelFrameComment")
                    Spacer()
                    if controller.saving { ProgressView().controlSize(.small); Text("Saving on the project drive…").font(ClautoDesign.caption) }
                    Button("Save Frame Comment") { Task { if await controller.save(), controller.draft == nil { close() } } }
                        .disabled(!draft.canSave || controller.saving || controller.preparing).accessibilityIdentifier("saveFrameComment")
                }
            } else {
                if let error = controller.error { Text(error).foregroundStyle(ClautoDesign.ember) }
                else { ClautoActivity(label: "Opening the saved frame…") }
                Button("Cancel") { if controller.cancel() { close() } }.keyboardShortcut(.cancelAction).disabled(controller.saving)
            }
        }.padding(24).frame(minWidth: 660,idealWidth: 820,maxWidth: 1000,minHeight: 560)
            .background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).font(ClautoDesign.body).clautoThemeAppearance()
    }
    @ViewBuilder private func annotationControls(_ draft: FrameCommentDraft, frame: FrozenReviewFrame) -> some View {
        HStack {
            Picker("Mark shape",selection: Binding(get: { draft.tool },set: { draft.tool = $0 })) {
                Text("Ellipse").tag(FrameAnnotationKind.ellipse); Text("Circle").tag(FrameAnnotationKind.circle)
            }.pickerStyle(.segmented).frame(width: 220)
            Button("Undo Mark") { draft.undo() }.disabled(!draft.history.canUndo).accessibilityIdentifier("undoFrameMark")
            Button("Redo Mark") { draft.redo() }.disabled(!draft.history.canRedo)
            Button("Remove Mark") { do { try draft.removeSelected() } catch { controller.error = error.localizedDescription } }
                .disabled(draft.selectedShapeID == nil).accessibilityIdentifier("removeFrameMark")
        }
        HStack(alignment: .bottom) {
            coordinate("Left (0–1)",text: $x); coordinate("Top (0–1)",text: $y)
            coordinate("Width (0–1)",text: $width)
            coordinate("Height (0–1)",text: $height).disabled(draft.tool == .circle)
            Button("Add Mark") {
                guard let left = Double(x), let top = Double(y), let w = Double(width), let h = draft.tool == .circle ? 0 : Double(height) else { controller.error = "Enter numeric bounds between zero and one."; return }
                do {
                    let actualHeight = draft.tool == .circle ? w*Double(frame.width)/Double(frame.height) : h
                    try draft.add(.init(x: left,y: top,width: w,height: actualHeight),kind: draft.tool); controller.error = nil
                } catch { controller.error = error.localizedDescription }
            }.disabled(draft.history.shapes.count >= 32).accessibilityIdentifier("addFrameMarkCoordinates")
        }
        Text(draft.tool == .circle ? "A circle uses equal pixel diameters; its height follows the video dimensions." : "Coordinates start at the top-left of the video, excluding its letterbox bars.")
            .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
        if !draft.history.shapes.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(draft.history.shapes.enumerated()),id: \.element.id) { index,shape in
                        Button("\(shape.kind == .circle ? "Circle" : "Ellipse") \(index+1)") { draft.selectedShapeID = shape.id }
                            .accessibilityAddTraits(draft.selectedShapeID == shape.id ? .isSelected : [])
                            .overlay(alignment: .bottom) { if draft.selectedShapeID == shape.id { Rectangle().fill(ClautoDesign.ember).frame(height: 2) } }
                    }
                }
            }.frame(height: 30)
        }
    }
    private func coordinate(_ title: String,text: Binding<String>) -> some View {
        VStack(alignment: .leading,spacing: 4) { Text(title).font(ClautoDesign.caption); TextField(title,text: text).labelsHidden().textFieldStyle(.roundedBorder) }.frame(maxWidth: 125)
    }
}

struct FrameAnnotationCanvas: NSViewRepresentable {
    @Bindable var draft: FrameCommentDraft
    var enabled: Bool
    func makeNSView(context: Context) -> AnnotationImageView { AnnotationImageView(frame: .zero) }
    func updateNSView(_ view: AnnotationImageView,context: Context) {
        view.draft = draft; view.editingEnabled = enabled
        if view.imageSHA != draft.frame?.pngSHA256 {
            view.image = draft.frame.flatMap { NSImage(data: $0.png) }; view.imageSHA = draft.frame?.pngSHA256
        }
        // Observation tracks these reads; redraw vector overlays after any edit.
        _ = draft.history.shapes; _ = draft.selectedShapeID; _ = draft.tool
        view.needsDisplay = true
    }
}
final class AnnotationImageView: NSView, NSUserInterfaceValidations {
    var draft: FrameCommentDraft?
    var editingEnabled = true
    var image: NSImage?
    var imageSHA: String?
    private var start: CGPoint?
    private var finish: CGPoint?
    private var dragKind = FrameAnnotationKind.ellipse
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { editingEnabled }
    private var video: CGRect? {
        guard let frame = draft?.frame else { return nil }
        return VideoAnnotationGeometry.videoRect(image: CGSize(width: frame.width,height: frame.height),canvas: bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image, let video, let draft else { return }
        image.draw(in: video,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
        for shape in draft.history.shapes {
            let path = NSBezierPath(ovalIn: VideoAnnotationGeometry.display(shape.bounds,video: video))
            NSColor.black.withAlphaComponent(0.8).setStroke(); path.lineWidth = shape.id == draft.selectedShapeID ? 6 : 5; path.stroke()
            NSColor.systemYellow.setStroke(); path.lineWidth = shape.id == draft.selectedShapeID ? 3 : 2; path.stroke()
        }
        if let start, let finish, let rect = VideoAnnotationGeometry.drawn(from: start,to: finish,kind: dragKind,video: video) {
            let path = NSBezierPath(ovalIn: VideoAnnotationGeometry.display(rect,video: video)); NSColor.white.setStroke(); path.lineWidth = 2; path.setLineDash([5,4],count: 2,phase: 0); path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard editingEnabled, let video, let draft else { return }
        let point = convert(event.locationInWindow,from: nil)
        guard video.contains(point) else { return }
        window?.makeFirstResponder(self); start = point; finish = point; dragKind = draft.tool; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { guard start != nil, editingEnabled else { return }; finish = convert(event.locationInWindow,from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; finish = nil; needsDisplay = true }
        guard editingEnabled, let start, let video, let draft,
              let rect = VideoAnnotationGeometry.drawn(from: start,to: convert(event.locationInWindow,from: nil),kind: dragKind,video: video) else { return }
        do { try draft.add(rect,kind: dragKind) } catch { NSSound.beep() }
    }
    @objc func undo(_ sender: Any?) { if editingEnabled { draft?.undo(); needsDisplay = true } }
    @objc func redo(_ sender: Any?) { if editingEnabled { draft?.redo(); needsDisplay = true } }
    @objc func delete(_ sender: Any?) { if editingEnabled { try? draft?.removeSelected(); needsDisplay = true } }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard editingEnabled else { return false }
        if item.action == #selector(undo(_:)) { return draft?.history.canUndo == true }
        if item.action == #selector(redo(_:)) { return draft?.history.canRedo == true }
        if item.action == #selector(delete(_:)) { return draft?.selectedShapeID != nil }
        return false
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51, event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty { delete(nil); return }
        super.keyDown(with: event)
    }
}
