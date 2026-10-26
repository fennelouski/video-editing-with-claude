import SwiftUI
import UniformTypeIdentifiers

struct HandwritingStudioView: View {
    @Bindable var controller: HandwritingStudioController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 26) {
                HandwritingRequestPanel(controller: controller)
                if let busy = controller.busy { HStack { ClautoActivity(label: busy);ClautoAction("Cancel",kind: .quiet) { controller.cancel() } } }
                if let issue = controller.issue { Text(issue).foregroundStyle(ClautoDesign.ember).textSelection(.enabled).accessibilityIdentifier("handwritingIssue") }
                if let notice = controller.notice { Text(notice).font(ClautoDesign.caption).textSelection(.enabled) }
                if !controller.documents.isEmpty {
                    ClautoDisclosure("Saved artwork & revisions") {
                        ForEach(controller.documents,id: \.revisionID) { value in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading,spacing: 3) { Text(value.exactText);Text("\(value.locale) · \(value.review.status.rawValue) · \(value.revisionID.uuidString.prefix(8))").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
                                Spacer();ClautoAction("Open revision") { controller.open(value.revisionID) }.disabled(controller.hasPendingWork)
                            }
                        }
                    }
                }
                if let document = controller.document {
                    HStack {
                        ClautoAction("Save revision",icon: .check,kind: .primary) { Task { _ = await controller.saveNow() } }.disabled(controller.busy != nil || !controller.dirty)
                        ClautoAction("Undo") { controller.undoChange() }.disabled(!controller.canUndo || controller.busy != nil)
                        ClautoAction("Redo") { controller.redoChange() }.disabled(!controller.canRedo || controller.busy != nil)
                        ClautoAction("Import recipe JSON") { importRecipe() }.disabled(controller.busy != nil)
                        ClautoAction("Save editable JSON") { exportRecipe() }.disabled(controller.busy != nil)
                        Spacer();Text(controller.dirty ? "Unsaved draft":"Saved with project").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    }
                    HandwritingPreviewPanel(controller: controller)
                    HandwritingExtractionPanel(controller: controller,document: document).disabled(controller.busy != nil)
                    HandwritingStrokePanel(controller: controller,document: document).disabled(controller.busy != nil)
                    HandwritingReviewPanel(controller: controller,document: document).disabled(controller.busy != nil)
                    ClautoSection("Export approved animation",detail: "Writes a transparent ProRes 4444 movie, an independent Final Cut layer and the editable recipe. Every frame uses the exact 24000/1001 timebase; artwork moves on twos.") {
                        ClautoAction("Export & verify",icon: .check,kind: .primary) { controller.exportAnimation() }.disabled(controller.busy != nil || document.review.status != .approved || controller.previewing)
                        if let result = controller.exported {
                            Text("\(result.proof.frameCount) frames decoded and verified · alpha retained").font(ClautoDesign.caption)
                            HStack {
                                ClautoAction("Show movie",icon: .folder) { NSWorkspace.shared.activateFileViewerSelecting([result.movieURL]) }
                                ClautoAction("Show Final Cut layer") { NSWorkspace.shared.activateFileViewerSelecting([result.timelineURL]) }
                                ClautoAction("Show recipe & originals") { NSWorkspace.shared.activateFileViewerSelecting([result.folderURL]) }
                            }
                        }
                    }
                }
                HandwritingStylesPanel(controller: controller)
            }.padding(28).frame(maxWidth: 1280,alignment: .leading)
        }.task { await controller.load() }.onDisappear { controller.stopPlayback() }
    }
    private func importRecipe() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.canChooseDirectories = false;panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK,let url = panel.url { controller.importDocument(url) } }
    }
    private func exportRecipe() {
        guard let bytes = controller.documentJSON() else { return }
        let panel = NSSavePanel();panel.allowedContentTypes = [.json];panel.nameFieldStringValue = "handwriting-editable.json"
        panel.begin { response in if response == .OK,let url = panel.url { do { try bytes.write(to: url,options: .atomic) } catch { controller.report(error.localizedDescription) } } }
    }
}

private struct HandwritingRequestPanel: View {
    @Bindable var controller: HandwritingStudioController
    var body: some View {
        ClautoSection("Handwriting studio",detail: "Supply exact text, create or import artwork, correct an editable reveal, then explicitly approve useful styles. Originals and every saved revision stay with this project.") {
            ClautoField(label: "Exact text · preserve spelling, spaces & diacritics",text: Binding(get: { controller.exactText },set: controller.setExactText),placeholder: "Seasoning a pan",axis: .vertical).accessibilityIdentifier("handwritingExactText")
            HStack(alignment: .top) {
                ClautoField(label: "Locale",text: Binding(get: { controller.locale },set: controller.setLocale),placeholder: "en / fr / ar").frame(width: 180)
                ClautoField(label: "Art direction",text: $controller.artDirection,placeholder: "Describe the lettering you want",axis: .vertical)
            }
            HStack {
                ClautoAction("Save AI artwork request") { saveRequest() }
                ClautoAction("Import artwork",icon: .add,kind: .primary) { chooseImage(regeneration: false) }.disabled(controller.hasPendingWork)
                if controller.document != nil { ClautoAction("Import regenerated revision") { chooseImage(regeneration: true) }.disabled(controller.hasPendingWork) }
            }
            Text("The app currently uses an import/provider boundary. Save a request for an available image-generation tool, then import the actual result with its receipt. Preparing a request does not generate an image.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            ClautoDisclosure("Artwork source & generation receipt") {
                ClautoChoice(title: "Source kind",selection: Binding(get: { controller.sourceKind },set: { kind in controller.sourceKind = kind;controller.updateProvenance { $0.kind = kind } }),options: [(.imported,"Imported original"),(.aiGenerated,"AI generated artwork"),(.fixture,"Test fixture · not live generation")])
                HStack {
                    ClautoField(label: "Provider / tool",text: Binding(get: { controller.provider },set: { text in controller.provider = text;controller.updateProvenance { $0.provider = text } }),placeholder: "Built-in image_gen / local scan")
                    ClautoField(label: "Model / version",text: Binding(get: { controller.model },set: { text in controller.model = text;controller.updateProvenance { $0.model = text } }),placeholder: "Receipt model or tool version")
                }
                ClautoField(label: "Generation request / receipt ID",text: Binding(get: { controller.requestID },set: { text in controller.requestID = text;controller.updateProvenance { $0.requestID = text } }),placeholder: "Required for AI artwork")
                ClautoTextArea(text: Binding(get: { controller.generationPrompt },set: { text in controller.generationPrompt = text;controller.change { $0.generationPrompt = text;$0.provenance.prompt = text } }),label: "Exact generation prompt").frame(height: 100)
                if let document = controller.document {
                    Text("Original: \(document.provenance.sourceName)\nSHA-256: \(document.provenance.sourceSHA256)").font(ClautoDesign.caption).textSelection(.enabled)
                }
            }
        }.disabled(controller.busy != nil)
    }
    private func chooseImage(regeneration: Bool) {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.png,.jpeg,.tiff,.heic];panel.canChooseDirectories = false;panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK,let url = panel.url { controller.importImage(url,regeneration: regeneration) } }
    }
    private func saveRequest() {
        guard let bytes = controller.prepareGenerationRequest() else { return }
        let panel = NSSavePanel();panel.allowedContentTypes = [.json];panel.nameFieldStringValue = "handwriting-request.json"
        panel.begin { response in
            if response == .OK,let url = panel.url { do { try bytes.write(to: url,options: .atomic) } catch { controller.report(error.localizedDescription) } }
        }
    }
}

private struct HandwritingPreviewPanel: View {
    @Bindable var controller: HandwritingStudioController
    @State private var showInk = false
    @State private var showOriginal = false
    @State private var background = "checker"
    @State private var showPaths = true
    var body: some View {
        ClautoSection("Inspect & replay",detail: HandwritingRecipe.capability) {
            HStack {
                ClautoToggle(title: "Inspect original",isOn: $showOriginal)
                ClautoToggle(title: "Show complete extracted ink",isOn: $showInk)
                ClautoToggle(title: "Show editable paths",isOn: $showPaths)
                ClautoChoice(title: "Alpha-edge inspection background",selection: $background,options: [("checker","Checkerboard"),("light","Light paper"),("dark","Dark paper")]).frame(width: 250)
            }
            if let raster = showOriginal ? controller.source:((showInk || controller.document?.recipe.strokes.isEmpty == true) ? controller.ink:controller.preview) {
                HandwritingCanvas(controller: controller,raster: raster,background: background,showPaths: showPaths).frame(height: 320)
            } else { Text(controller.previewing ? "Updating extracted ink and reveal…":"Derive reveal paths or draw your first path.").frame(maxWidth: .infinity,minHeight: 200).background(ClautoDesign.soft) }
            HStack {
                ClautoAction(controller.playing ? "Pause":"Replay") { if controller.playing { controller.stopPlayback() } else { showInk = false;showOriginal = false;controller.replay() } }.disabled(controller.previewing || controller.document?.recipe.strokes.isEmpty != false)
                Slider(value: Binding(get: { Double(controller.previewFrame) },set: { controller.stopPlayback();controller.previewFrame = Int($0) }),in: 0...Double(max(1,(controller.document?.recipe.frameCount ?? 2)-1)),step: 1).disabled(controller.previewing).accessibilityLabel("Handwriting preview frame")
                Text("Frame \(controller.previewFrame+1) / \(controller.document?.recipe.frameCount ?? 2)").font(ClautoDesign.caption).monospacedDigit()
            }
            if controller.previewing { ClautoActivity(label: "Checking mask coverage and alpha…") }
            if let quality = controller.quality {
                Text("\(quality.inkPixels) ink pixels · \(quality.partialAlphaPixels) soft edge pixels · \(quality.unrevealedPixels) unrevealed · \(quality.boundaryInkPixels) touching canvas boundary").font(ClautoDesign.caption).textSelection(.enabled)
                if quality.unrevealedPixels > 0 { Text("Some ink remains outside the reveal paths. Widen or correct paths before approval; the final frame does not silently fill missing ink.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
                if quality.boundaryInkPixels > 0 { Text("Ink touches the canvas edge. Check for clipped letters and import an original with clear margins before approval.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
            }
        }
    }
}

private struct HandwritingCanvas: View {
    @Bindable var controller: HandwritingStudioController
    let raster: CutoutRaster
    let background: String
    let showPaths: Bool
    @State private var gesturePoints: [CutoutPoint] = []
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width/CGFloat(raster.width),geometry.size.height/CGFloat(raster.height))
            let size = CGSize(width: CGFloat(raster.width)*scale,height: CGFloat(raster.height)*scale)
            ZStack(alignment: .topLeading) {
                Canvas { context,_ in
                    context.fill(Path(CGRect(origin: .zero,size: size)),with: .color(background == "dark" ? Color(red: 0.18,green: 0.20,blue: 0.17):Color(red: 0.95,green: 0.93,blue: 0.88)))
                    if background == "checker" {
                        for y in stride(from: CGFloat(0),to: size.height,by: 16) { for x in stride(from: CGFloat(0),to: size.width,by: 16) where (Int(x/16)+Int(y/16))%2 == 0 { context.fill(Path(CGRect(x: x,y: y,width: 16,height: 16)),with: .color(.gray.opacity(0.18))) } }
                    }
                }.frame(width: size.width,height: size.height).accessibilityHidden(true)
                if let image = try? CutoutImageIO.image(raster) { Image(decorative: image,scale: 1).resizable().frame(width: size.width,height: size.height) }
                Canvas { context,_ in
                    if showPaths,let document = controller.document {
                        for stroke in document.recipe.strokes {
                            let path = makePath(stroke.points,size: size)
                            context.stroke(path,with: .color(stroke.id == controller.selectedStroke?.id ? ClautoDesign.ember:ClautoDesign.ink.opacity(0.25)),lineWidth: stroke.id == controller.selectedStroke?.id ? 2:1)
                            if let start = (stroke.reverse ? stroke.points.last:stroke.points.first) { context.fill(Path(ellipseIn: CGRect(x: start.x*size.width-3,y: start.y*size.height-3,width: 6,height: 6)),with: .color(ClautoDesign.ember)) }
                        }
                    }
                    context.stroke(makePath(gesturePoints,size: size),with: .color(ClautoDesign.ember),lineWidth: 2)
                }.frame(width: size.width,height: size.height).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard controller.busy == nil,gesturePoints.count < 1024,size.width>0,size.height>0 else { return }
                    let point = CutoutPoint(x: max(0,min(1,event.location.x/size.width)),y: max(0,min(1,event.location.y/size.height)))
                    if gesturePoints.last != point { gesturePoints.append(point) }
                }.onEnded { _ in controller.addCanvasStroke(gesturePoints);gesturePoints = [] })
                    .accessibilityLabel("Editable handwriting mask canvas. Drag to draw, replace a path or paint cleanup. Keyboard path coordinates are available below.")
            }.frame(width: geometry.size.width,height: geometry.size.height,alignment: .center)
        }
    }
    private func makePath(_ points: [CutoutPoint],size: CGSize) -> Path {
        var path = Path();guard let first = points.first else { return path };path.move(to: .init(x: first.x*size.width,y: first.y*size.height));for point in points.dropFirst() { path.addLine(to: .init(x: point.x*size.width,y: point.y*size.height)) };return path
    }
}

private struct HandwritingExtractionPanel: View {
    @Bindable var controller: HandwritingStudioController
    let document: HandwritingDocument
    var body: some View {
        ClautoSection("Separate lettering & clean edges",detail: "Preserve supplied alpha, or key a light/dark paper background. Paper keying recovers edge colors into the declared ink color; the original stays unchanged.") {
            HStack {
                ClautoChoice(title: "Background separation",selection: Binding(get: { document.recipe.extraction.mode },set: { mode in controller.change { $0.recipe.extraction.mode = mode } }),options: [(.sourceAlpha,"Use original transparency"),(.lightPaper,"Dark lettering on light paper"),(.darkPaper,"Light lettering on dark paper")])
                ClautoNumberField(label: "Coverage cutoff (0–0.95)",value: Binding(get: { document.recipe.extraction.threshold },set: { value in if value.isFinite,(0...0.95).contains(value) { controller.change { $0.recipe.extraction.threshold = value } } }))
                ClautoNumberField(label: "Edge softness (0.001–1)",value: Binding(get: { document.recipe.extraction.softness },set: { value in if value.isFinite,(0.001...1).contains(value) { controller.change { $0.recipe.extraction.softness = value } } }))
            }
            if document.recipe.extraction.mode != .sourceAlpha {
                HStack { inkChannel("Ink red",\.inkRed);inkChannel("Ink green",\.inkGreen);inkChannel("Ink blue",\.inkBlue) }
            }
            HStack {
                ClautoChoice(title: "Canvas tool",selection: $controller.canvasMode,options: [(.path,"Draw a new reveal path"),(.replacePath,"Replace selected path"),(.erase,"Erase background / stray ink"),(.restore,"Restore original ink")])
                ClautoNumberField(label: "Brush radius · source pixels",value: $controller.brushRadius)
                ClautoAction("Clear cleanup") { controller.clearCleanup() }.disabled(document.recipe.extraction.cleanup.isEmpty)
            }
            Text("\(document.recipe.extraction.cleanup.count) cleanup strokes. Cleanup changes the mask; drawn reveal paths define when ink appears.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
        }
    }
    private func inkChannel(_ label: String,_ path: WritableKeyPath<HandwritingExtraction,UInt8>) -> some View {
        ClautoNumberField(label: label,value: Binding(get: { Double(document.recipe.extraction[keyPath: path]) },set: { value in guard value.isFinite,(1...254).contains(value) else { return };controller.change { $0.recipe.extraction[keyPath: path] = UInt8(value) } }))
    }
}

private struct HandwritingStrokePanel: View {
    @Bindable var controller: HandwritingStudioController
    let document: HandwritingDocument
    @State private var fromX = 10.0
    @State private var fromY = 50.0
    @State private var toX = 90.0
    @State private var toY = 50.0
    var body: some View {
        ClautoSection("Fine-tune the writing",detail: "Path order is editable. Start frames are explicit, so paths can overlap; duration and pauses use even integer frames. A dot marks each path’s writing start.") {
            HStack {
                ClautoAction("Derive paths from actual ink",kind: .primary) { controller.derivePaths() }
                ClautoNumberField(label: "Overlap when retiming · even frames",value: $controller.overlapFrames)
                ClautoAction("Retime in path order") { controller.retime() }.disabled(document.recipe.strokes.isEmpty)
                ClautoNumberField(label: "Animation length · even frames",value: Binding(get: { Double(document.recipe.frameCount) },set: { value in if value.isFinite,(2...2400).contains(value) { controller.change { $0.recipe.frameCount = Int(value)/2*2 } } }))
            }
            if !document.recipe.strokes.isEmpty {
                ClautoChoice(title: "Reveal path",selection: Binding(get: { controller.selectedStroke?.id ?? document.recipe.strokes[0].id },set: { controller.selectedStrokeID = $0 }),options: document.recipe.strokes.enumerated().map { index,stroke in (stroke.id,"Path \(index+1) · \(stroke.points.count) points · frame \(stroke.startFrame) → \(stroke.startFrame+stroke.durationFrames)") })
            }
            if let stroke = controller.selectedStroke {
                HStack {
                    frameField("Start frame",stroke: stroke,path: \.startFrame,minimum: 0)
                    frameField("Duration frames",stroke: stroke,path: \.durationFrames,minimum: 2)
                    frameField("Pause after · used by Retime",stroke: stroke,path: \.pauseAfterFrames,minimum: 0)
                    ClautoNumberField(label: "Mask width · source pixels",value: Binding(get: { stroke.maskWidthPixels },set: { value in if value.isFinite,(0.5...16384).contains(value) { controller.updateStroke(stroke.id) { $0.maskWidthPixels = value } } }))
                }
                HStack {
                    ClautoChoice(title: "Easing",selection: Binding(get: { stroke.easing },set: { value in controller.updateStroke(stroke.id) { $0.easing = value } }),options: [(.linear,"Linear"),(.easeInOut,"Ease in & out")])
                    ClautoToggle(title: "Reverse writing direction",isOn: Binding(get: { stroke.reverse },set: { value in controller.updateStroke(stroke.id) { $0.reverse = value } }))
                    ClautoAction("Earlier") { controller.moveStroke(stroke.id,by: -1) }
                    ClautoAction("Later") { controller.moveStroke(stroke.id,by: 1) }
                    ClautoAction("Remove path",kind: .quiet) { controller.removeStroke(stroke.id) }
                }
            }
            ClautoDisclosure("Keyboard path correction") {
                Text("Add a straight segment, or replace the selected path. Draw on the image for curved paths. Coordinates are percentages of the oriented original.").font(ClautoDesign.caption)
                HStack { ClautoNumberField(label: "From X %",value: $fromX);ClautoNumberField(label: "From Y %",value: $fromY);ClautoNumberField(label: "To X %",value: $toX);ClautoNumberField(label: "To Y %",value: $toY) }
                HStack {
                    ClautoAction("Add segment") { addSegment(replace: false) }
                    ClautoAction("Replace selected path") { addSegment(replace: true) }.disabled(controller.selectedStroke == nil)
                }
            }
        }
    }
    private func frameField(_ label: String,stroke: HandwritingStroke,path: WritableKeyPath<HandwritingStroke,Int>,minimum: Double) -> some View {
        ClautoNumberField(label: label,value: Binding(get: { Double(stroke[keyPath: path]) },set: { value in guard value.isFinite,(minimum...2400).contains(value) else { return };controller.updateStroke(stroke.id) { $0[keyPath: path] = Int(value)/2*2 } }))
    }
    private func addSegment(replace: Bool) {
        guard [fromX,fromY,toX,toY].allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { controller.report("Path coordinates must be percentages from 0 to 100.");return }
        let points = [CutoutPoint(x: fromX/100,y: fromY/100),CutoutPoint(x: toX/100,y: toY/100)]
        if replace,let stroke = controller.selectedStroke { controller.updateStroke(stroke.id) { $0.points = points } }
        else { let tool = controller.canvasMode;controller.canvasMode = .path;controller.addCanvasStroke(points);controller.canvasMode = tool }
    }
}

private struct HandwritingReviewPanel: View {
    @Bindable var controller: HandwritingStudioController
    let document: HandwritingDocument
    var body: some View {
        ClautoSection("Review this exact revision",detail: "Likes alone do not approve a style. Check the rendered spelling and every diacritic against the exact text, inspect alpha edges on light and dark backgrounds, then approve explicitly.") {
            Text(document.exactText).font(ClautoDesign.type(22,weight: .semibold)).textSelection(.enabled)
            HStack { reviewToggle("I like this style",\.liked);reviewToggle("Spelling & diacritics checked",\.spellingChecked);reviewToggle("Alpha edges checked",\.alphaEdgesChecked) }
            ClautoField(label: "Reviewed by",text: Binding(get: { document.review.reviewer },set: { value in controller.change({ $0.review.reviewer = value },visual: false) }),placeholder: "Your name")
            ClautoTextArea(text: Binding(get: { document.review.comments },set: { value in controller.change({ $0.review.comments = value },visual: false) }),label: "Why you like it, or why it was rejected").frame(height: 90)
            ClautoField(label: "Suitable contexts · separate with commas",text: Binding(get: { document.review.contexts.joined(separator: ", ") },set: { text in controller.change({ $0.review.contexts = text.split(separator: ",",omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } },visual: false) }),placeholder: "Chapter titles, warm kitchen explanations")
            HStack {
                ClautoAction("Approve this revision",icon: .check,kind: .primary) { controller.approve() }.disabled(!controller.canApprove || document.review.status == .approved)
                ClautoAction("Reject & keep revision",kind: .quiet) { controller.reject() }.disabled(document.review.comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Status: \(document.review.status.rawValue)").font(ClautoDesign.caption)
            }
            Text("Changing text, source, extraction or animation resets the spelling and edge checks. Rejected versions remain in history; import a regenerated revision to try again.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
        }
    }
    private func reviewToggle(_ title: String,_ path: WritableKeyPath<HandwritingReview,Bool>) -> some View {
        ClautoToggle(title: title,isOn: Binding(get: { document.review[keyPath: path] },set: { value in controller.change({ $0.review[keyPath: path] = value },visual: false) }))
    }
}

private struct HandwritingStylesPanel: View {
    @Bindable var controller: HandwritingStudioController
    var body: some View {
        ClautoSection("Approved reusable styles",detail: "Future agents discover only explicitly approved presets with your reasons and suitable contexts. New artwork always requires its own review.") {
            if controller.document?.review.status == .approved {
                HStack {
                    ClautoField(label: "Style name",text: $controller.styleName,placeholder: "Warm kitchen marker")
                    ClautoAction("Save approved style",icon: .check,kind: .primary) { controller.saveStyle() }.disabled(controller.busy != nil || controller.styleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if controller.styles.isEmpty { Text("No approved styles yet. Drafts and rejected artwork do not teach future agents your preferences.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
            ForEach(controller.styles) { style in
                VStack(alignment: .leading,spacing: 7) {
                    HStack { Text(style.name).font(ClautoDesign.type(16,weight: .semibold));Spacer();ClautoAction("Apply approved settings") { controller.applyStyle(style) }.disabled(controller.busy != nil) }
                    Text(style.review.comments).textSelection(.enabled)
                    Text("Use for: \(style.review.contexts.joined(separator: ", ")) · Approved by \(style.review.reviewer) · \(style.locale)").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    Text("Source revision \(style.sourceRevisionID.uuidString.prefix(8)) · \(style.provenance.kind.rawValue) · \(style.provenance.provider)").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                }.padding(14).background(ClautoDesign.soft)
            }
        }
    }
}
