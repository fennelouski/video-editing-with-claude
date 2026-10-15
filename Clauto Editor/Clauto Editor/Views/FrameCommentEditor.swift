import SwiftUI
import AppKit

struct FrameCommentEditor: View {
    @Bindable var controller: FrameCommentController
    let close: () -> Void
    @State private var x = "0.25"
    @State private var y = "0.25"
    @State private var width = "0.25"
    @State private var height = "0.25"
    @State private var drawingPoints = "0.25,0.25; 0.5,0.5"
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
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
                Text("Click a detail to tag it, or draw a mark and add its note. Marks stay on this saved frame; they do not track objects or approve video changes.")
                    .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                if let issue = draft.validationIssue, draft.frame != nil { Text(issue).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
                if let error = controller.error { Text(error).foregroundStyle(ClautoDesign.ember).font(ClautoDesign.caption).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { if controller.cancel() { close() } }.keyboardShortcut(.cancelAction).disabled(controller.saving).accessibilityIdentifier("cancelFrameComment")
                    Spacer()
                    if controller.saving { ProgressView().controlSize(.small); Text("Saving on the project drive…").font(ClautoDesign.caption) }
                    Button("Save Frame Comment") { Task { if await controller.save(), controller.draft == nil { close() } } }
                        .disabled(!draft.canAttemptSave || controller.saving || controller.preparing).accessibilityIdentifier("saveFrameComment")
                }
            } else {
                if let error = controller.error { Text(error).foregroundStyle(ClautoDesign.ember) }
                else { ClautoActivity(label: "Opening the saved frame…") }
                Button("Cancel") { if controller.cancel() { close() } }.keyboardShortcut(.cancelAction).disabled(controller.saving)
            }
        }.padding(24) }.frame(minWidth: 840,idealWidth: 900,maxWidth: 1100,minHeight: 560,idealHeight: 780,maxHeight: 900)
            .background(ClautoDesign.paper).foregroundStyle(ClautoDesign.ink).font(ClautoDesign.body).clautoThemeAppearance()
            .onChange(of: controller.draft?.selectedShapeID) {
                if let draft = controller.draft, let shape = draft.history.shapes.first(where: { $0.id == draft.selectedShapeID }) {
                    x = String(shape.bounds.x); y = String(shape.bounds.y); width = String(shape.bounds.width); height = String(shape.bounds.height)
                }
            }
    }
    @ViewBuilder private func annotationControls(_ draft: FrameCommentDraft, frame: FrozenReviewFrame) -> some View {
        HStack {
            Button("Select") { draft.selecting.toggle() }.accessibilityLabel("Toggle mark selection mode")
                .accessibilityAddTraits(draft.selecting ? .isSelected : [])
                .overlay(alignment: .bottom) { if draft.selecting { Rectangle().fill(ClautoDesign.ember).frame(height: 2) } }
            Picker("Mark shape",selection: Binding(get: { draft.tool },set: { draft.tool = $0; draft.selecting = false })) {
                ForEach(FrameAnnotationKind.allCases,id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).frame(width: 300)
            Button("Undo Change") { draft.undo() }.disabled(!draft.history.canUndo).accessibilityIdentifier("undoFrameMark")
            Button("Redo Change") { draft.redo() }.disabled(!draft.history.canRedo)
            Button("Remove Mark") { do { try draft.removeSelected() } catch { controller.error = error.localizedDescription } }
                .disabled(draft.selectedShapeID == nil).accessibilityIdentifier("removeFrameMark")
        }
        if draft.tool == .freehand {
            HStack {
                TextField("Drawing points (x,y; x,y)",text: $drawingPoints).textFieldStyle(.roundedBorder)
                Button("Add Drawing") {
                    let pairs = drawingPoints.split(separator: ";",omittingEmptySubsequences: false)
                    let points: [CGPoint] = pairs.compactMap { pair in
                        let xy = pair.split(separator: ",",omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                        guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]), x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
                        return CGPoint(x: x*Double(frame.width),y: y*Double(frame.height))
                    }
                    guard points.count == pairs.count else { controller.error = "Enter drawing points as x,y; x,y, with coordinates between zero and one."; return }
                    do { try draft.addStroke(points,video: .init(x: 0,y: 0,width: frame.width,height: frame.height)); controller.error = nil } catch { controller.error = error.localizedDescription }
                }.disabled(draft.history.shapes.count >= 32)
            }
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
            }.disabled(draft.history.shapes.count >= 32 || draft.tool == .freehand).accessibilityIdentifier("addFrameMarkCoordinates")
            Button("Update Bounds") {
                guard let left = Double(x), let top = Double(y), let w = Double(width), let h = Double(height) else { controller.error = "Enter numeric bounds."; return }
                let selected = draft.history.shapes.first { $0.id == draft.selectedShapeID }
                let actualHeight = selected?.kind == .circle ? w*Double(frame.width)/Double(frame.height):h
                do { try draft.resizeSelected(.init(x: left,y: top,width: w,height: actualHeight)); controller.error = nil } catch { controller.error = error.localizedDescription }
            }.disabled(draft.selectedShapeID == nil)
        }
        Text(draft.tool == .circle ? "A circle uses equal pixel diameters; its height follows the video dimensions." : "Coordinates start at the top-left of the video, excluding its letterbox bars.")
            .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
        if !draft.history.shapes.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(draft.history.shapes.enumerated()),id: \.element.id) { index,shape in
                        Button("\(shape.tag ?? shape.kind.label) \(index+1)") { draft.selectedShapeID = shape.id }
                            .accessibilityAddTraits(draft.selectedShapeID == shape.id ? .isSelected : [])
                            .overlay(alignment: .bottom) { if draft.selectedShapeID == shape.id { Rectangle().fill(ClautoDesign.ember).frame(height: 2) } }
                    }
                }
            }.frame(height: 30)
        }
        if let selected = draft.history.shapes.first(where: { $0.id == draft.selectedShapeID }) {
            TextField("Region label",text: Binding(get: { draft.history.shapes.first(where: { $0.id == selected.id })?.tag ?? "" },set: { value in
                guard !controller.saving else { return }
                do { try draft.updateRegion(selected.id,tag: value,note: draft.history.shapes.first(where: { $0.id == selected.id })?.note ?? "") } catch { controller.error = error.localizedDescription }
            })).textFieldStyle(.roundedBorder).accessibilityLabel("Label for selected region").id("region-label-"+selected.id.uuidString)
            TextField("Note about this region",text: Binding(get: { draft.history.shapes.first(where: { $0.id == selected.id })?.note ?? "" },set: { value in
                guard !controller.saving else { return }
                do { try draft.updateRegion(selected.id,tag: draft.history.shapes.first(where: { $0.id == selected.id })?.tag ?? "",note: value) } catch { controller.error = error.localizedDescription }
            }),axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder).accessibilityLabel("Written note for selected region").id("region-note-"+selected.id.uuidString)
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
        _ = draft.selecting
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
    private var dragSelecting = false
    private var dragDraftID: UUID?
    private var gesture: FrameMarkGesture?
    private var stroke: [CGPoint] = []
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
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: video).addClip()
        for shape in draft.history.shapes {
            let rect = VideoAnnotationGeometry.display(shape.bounds,video: video)
            let path: NSBezierPath
            if shape.kind == .freehand, let points = shape.points {
                path = NSBezierPath()
                for (i,point) in points.enumerated() { let shown = CGPoint(x: video.minX+point.x*video.width,y: video.minY+point.y*video.height); if i == 0 { path.move(to: shown) } else { path.line(to: shown) } }
                path.lineJoinStyle = .round; path.lineCapStyle = .round
            } else if shape.kind == .highlight {
                path = NSBezierPath(rect: rect); NSColor.systemYellow.withAlphaComponent(0.25).setFill(); path.fill()
            } else { path = NSBezierPath(ovalIn: rect) }
            NSColor.black.withAlphaComponent(0.8).setStroke(); path.lineWidth = shape.id == draft.selectedShapeID ? 6 : 5; path.stroke()
            NSColor.systemYellow.setStroke(); path.lineWidth = shape.id == draft.selectedShapeID ? 3 : 2; path.stroke()
            if let tag = shape.tag {
                (tag as NSString).draw(at: .init(x: rect.minX+4,y: rect.minY+3),withAttributes: [.font:NSFont.systemFont(ofSize: 12,weight: .semibold),.foregroundColor:NSColor.white,.backgroundColor:NSColor.black.withAlphaComponent(0.8)])
            }
        }
        if !dragSelecting, let start, let finish {
            let path: NSBezierPath
            if dragKind == .freehand {
                path = NSBezierPath(); path.move(to: start)
                for point in stroke.dropFirst() { if let normal = VideoAnnotationGeometry.normalize(point,video: video) { path.line(to: .init(x: video.minX+normal.x*video.width,y: video.minY+normal.y*video.height)) } }
            } else if let rect = VideoAnnotationGeometry.drawn(from: start,to: finish,kind: dragKind,video: video) {
                let shown = VideoAnnotationGeometry.display(rect,video: video)
                path = dragKind == .highlight ? NSBezierPath(rect: shown):NSBezierPath(ovalIn: shown)
            } else { return }
            NSColor.white.setStroke(); path.lineWidth = 2; path.setLineDash([5,4],count: 2,phase: 0); path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard editingEnabled, let video, let draft else { return }
        let point = convert(event.locationInWindow,from: nil)
        guard video.contains(point) else { return }
        window?.makeFirstResponder(self); start = point; finish = point; stroke = [point]; gesture = .init(start: point); dragKind = draft.tool; dragSelecting = draft.selecting; dragDraftID = draft.id; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard start != nil, editingEnabled, draft?.id == dragDraftID else { return }
        let point = convert(event.locationInWindow,from: nil); finish = point; gesture?.observe(point)
        if stroke.count >= 512 { stroke = stride(from: 0,to: stroke.count,by: 2).map { stroke[$0] } }
        stroke.append(point); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; finish = nil; stroke = []; dragDraftID = nil; gesture = nil; needsDisplay = true }
        guard editingEnabled, let start, let video, let draft, draft.id == dragDraftID else { return }
        let end = convert(event.locationInWindow,from: nil); gesture?.observe(end)
        let click = gesture?.isClick == true
        if dragSelecting || click {
            let hit = draft.history.shapes.reversed().first { VideoAnnotationGeometry.display($0.bounds,video: video).insetBy(dx: -4,dy: -4).contains(end) }
            draft.selectedShapeID = hit?.id
            if hit != nil || dragSelecting { return }
            if let pin = VideoAnnotationGeometry.pin(at: end,video: video) { try? draft.add(pin,kind: .circle) }
            return
        }
        do {
            if dragKind == .freehand {
                if stroke.count >= 512 { stroke = stride(from: 0,to: stroke.count,by: 2).map { stroke[$0] } }
                try draft.addStroke(stroke+[end],video: video)
            } else if let rect = VideoAnnotationGeometry.drawn(from: start,to: end,kind: dragKind,video: video) { try draft.add(rect,kind: dragKind) }
        } catch { NSSound.beep() }
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
