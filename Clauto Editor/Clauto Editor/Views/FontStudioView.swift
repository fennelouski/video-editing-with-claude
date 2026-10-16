import SwiftUI
import UniformTypeIdentifiers

struct FontStudioView: View {
    @Bindable var controller: FontStudioController
    @State private var newName = "My custom font"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 24) {
                ClautoSection("Font studio",detail: "Turn your images into editable characters. Original images, mapping drafts and every compiled font revision stay with this project.") {
                    HStack(alignment: .bottom) {
                        ClautoField(label: "New font name",text: $newName,placeholder: "Name this font")
                        ClautoAction("Create font",icon: .add,kind: .primary) { controller.create(label: newName) }.disabled(controller.hasPendingWork)
                    }
                    if !controller.fonts.isEmpty {
                        ClautoChoice(title: "Saved fonts",selection: Binding(get: { controller.draft?.id ?? controller.fonts[0].id },set: controller.open),options: controller.fonts.map { ($0.id,"\($0.label) · \($0.glyphCount) characters") }).disabled(controller.hasPendingWork)
                        if controller.draft == nil { ClautoAction("Open selected font") { controller.open(controller.fonts[0].id) } }
                    }
                }
                if let busy = controller.busy { HStack { ClautoActivity(label: busy);ClautoAction("Cancel",kind: .quiet) { controller.cancel() } } }
                if let issue = controller.issue { Text(issue).foregroundStyle(ClautoDesign.ember).textSelection(.enabled).accessibilityIdentifier("fontStudioIssue") }
                if controller.conflict { ClautoAction("Keep both font workspaces") { controller.keepBoth() } }
                if let draft = controller.draft {
                    ClautoSection(draft.label,detail: "Custom font mode lets you trace, replace and edit outlines. The original scan-only HerMarker workflow keeps its separate rules.") {
                        HStack {
                            ClautoAction("Add images or folder",icon: .folder,kind: .primary) { chooseImages() }
                            ClautoAction("Add generated character") { controller.addGeneratedMapping() }
                            ClautoAction("Undo") { controller.undoChange() }.disabled(!controller.canUndo)
                            ClautoAction("Redo") { controller.redoChange() }.disabled(!controller.canRedo)
                            ClautoAction("Save mapping") { Task { _ = await controller.saveNow() } }.disabled(!controller.dirty || controller.saving)
                        }.disabled(controller.busy != nil)
                        Text(controller.saving ? "Saving mapping…":"Mappings and incomplete fields save automatically.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                    }
                    if !draft.pendingMappings.isEmpty {
                        ClautoSection("Map the next character") {
                            ClautoChoice(title: "Pending image or generated character",selection: Binding(get: { controller.selectedMappingID ?? draft.pendingMappings[0].id },set: { controller.selectedMappingID = $0 }),options: draft.pendingMappings.map { mapping in
                                let source = draft.sources.first { $0.id==mapping.sourceID }
                                return (mapping.id,(source?.name ?? "Generated fallback")+" → "+(mapping.character.isEmpty ? "choose character":mapping.character))
                            })
                            if let mapping = draft.pendingMappings.first(where: { $0.id == (controller.selectedMappingID ?? draft.pendingMappings[0].id) }) {
                                FontMappingView(controller: controller,mapping: mapping).id(mapping.id)
                            }
                        }.disabled(controller.busy != nil)
                    }
                    if !draft.sources.isEmpty {
                        ClautoDisclosure("Use another cell from an image sheet") {
                            ForEach(draft.sources) { source in
                                HStack { Text(source.name);Spacer();ClautoAction("Map another cell") { controller.addMapping(sourceID: source.id) } }
                            }
                        }.disabled(controller.busy != nil)
                    }
                    if !draft.glyphs.isEmpty {
                        ClautoSection("Edit characters") {
                            ClautoChoice(title: "Character",selection: Binding(get: { controller.selectedGlyphID ?? draft.glyphs[0].id },set: { controller.selectedGlyphID = $0 }),options: draft.glyphs.map { ($0.id,"\($0.character) · \($0.provenanceLabel)") })
                            if let glyph = draft.glyphs.first(where: { $0.id == (controller.selectedGlyphID ?? draft.glyphs[0].id) }) {
                                FontOutlineEditor(controller: controller,glyph: glyph).id(glyph.id)
                                ClautoAction("Retrace or remap this character") { controller.remapGlyph(glyph) }
                            }
                        }.disabled(controller.busy != nil)
                        ClautoAction("Build TTF & WOFF2",icon: .check,kind: .primary) { controller.compileFont() }.disabled(controller.busy != nil)
                    }
                    if let revision = draft.currentFontRevisionID {
                        FontRevisionView(controller: controller,fontID: draft.id,currentRevision: revision).id(revision)
                    }
                }
            }.padding(28).frame(maxWidth: 1250,alignment: .leading)
        }.task { await controller.load() }
    }
    private func chooseImages() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.png,.jpeg,.tiff,.heic];panel.canChooseFiles = true;panel.canChooseDirectories = true;panel.allowsMultipleSelection = true
        panel.begin { response in if response == .OK { controller.importSelection(panel.urls) } }
    }
}

private struct FontMappingView: View {
    @Bindable var controller: FontStudioController
    let mapping: FontPendingMapping
    @State private var raster: CutoutRaster?
    @State private var imageIssue: String?
    private var source: FontStudioSource? { controller.draft?.sources.first { $0.id==mapping.sourceID } }
    private func field(_ path: WritableKeyPath<FontPendingMapping,String>) -> Binding<String> {
        Binding(get: { controller.draft?.pendingMappings.first(where: { $0.id==mapping.id })?[keyPath: path] ?? mapping[keyPath: path] },set: { value in controller.updateMapping(mapping.id) { $0[keyPath: path] = value } })
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack(alignment: .top,spacing: 24) {
                if let source {
                    VStack(alignment: .leading,spacing: 8) {
                        if let raster { FontCropCanvas(raster: raster,mapping: mapping) { crop in controller.updateMapping(mapping.id) { $0.crop = crop.map { String($0) } } }.frame(height: 280) }
                        else if imageIssue == nil { ClautoActivity(label: "Opening oriented image…").frame(height: 180) }
                        Text("Drag a cell around the character in \(source.name). The baseline is relative to that cell.").font(ClautoDesign.caption)
                        if let imageIssue { Text(imageIssue).foregroundStyle(ClautoDesign.ember) }
                    }.frame(maxWidth: .infinity)
                } else {
                    Text("Generated from licensed Work Sans. This character is labelled as a fallback and keeps its source and OFL license; it does not imitate your handwriting.").font(ClautoDesign.caption).frame(maxWidth: .infinity,alignment: .leading)
                }
                VStack(alignment: .leading,spacing: 12) {
                    ClautoField(label: "One character",text: field(\.character),placeholder: "A")
                    if source != nil {
                        HStack { cropField(0,"Left");cropField(1,"Top") }
                        HStack { cropField(2,"Width");cropField(3,"Height") }
                        ClautoField(label: "Baseline in cell (0–1)",text: field(\.baseline),placeholder: "0.8")
                        ClautoField(label: "Ink threshold (0.01–0.99)",text: field(\.threshold),placeholder: "0.55")
                    }
                    if let existing = controller.draft?.glyphs.first(where: { $0.character==mapping.character }) {
                        ClautoToggle(title: "Replace existing character \(existing.character)",isOn: Binding(get: { mapping.replaceGlyphID==existing.id },set: { selected in controller.updateMapping(mapping.id) { $0.replaceGlyphID = selected ? existing.id:nil } }))
                    }
                    HStack {
                        ClautoAction(source == nil ? "Generate character":"Trace character",kind: .primary) { controller.trace(mapping.id) }
                        ClautoAction("Remove mapping",kind: .quiet) { controller.removeMapping(mapping.id) }
                    }
                }.frame(width: 310)
            }
        }.task(id: source?.id) {
            raster = nil;imageIssue = nil
            guard let source,let draft = controller.draft else { return }
            do { let result = try await controller.repository.previewRaster(controller.project,fontID: draft.id,source: source);try Task.checkCancellation();raster = result }
            catch is CancellationError {} catch { imageIssue = error.localizedDescription }
        }
    }
    private func cropField(_ index: Int,_ label: String) -> some View {
        ClautoField(label: label+" (0–1)",text: Binding(get: { mapping.crop[index] },set: { text in controller.updateMapping(mapping.id) { $0.crop[index] = text } }),placeholder: index < 2 ? "0":"1")
    }
}

private struct FontCropCanvas: View {
    let raster: CutoutRaster
    let mapping: FontPendingMapping
    let crop: ([Double]) -> Void
    @State private var selection: CGRect?
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width/CGFloat(raster.width),geometry.size.height/CGFloat(raster.height))
            let size = CGSize(width: CGFloat(raster.width)*scale,height: CGFloat(raster.height)*scale)
            ZStack(alignment: .topLeading) {
                if let image = try? CutoutImageIO.image(raster) { Image(decorative: image,scale: 1).resizable().frame(width: size.width,height: size.height) }
                Canvas { context,_ in
                    let values = mapping.crop.compactMap(Double.init)
                    if let box = selection ?? (values.count == 4 && values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) ? CGRect(x: values[0]*size.width,y: values[1]*size.height,width: values[2]*size.width,height: values[3]*size.height):nil) {
                        context.stroke(Path(box),with: .color(ClautoDesign.ember),lineWidth: 2)
                        if let baseline = Double(mapping.baseline),baseline.isFinite,(0...1).contains(baseline) {
                            var line = Path();line.move(to: .init(x: box.minX,y: box.minY+box.height*baseline));line.addLine(to: .init(x: box.maxX,y: box.minY+box.height*baseline));context.stroke(line,with: .color(ClautoDesign.ember),style: .init(lineWidth: 1,dash: [5,3]))
                        }
                    }
                }.frame(width: size.width,height: size.height).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1).onChanged { event in
                    let a = CGPoint(x: min(size.width,max(0,event.startLocation.x)),y: min(size.height,max(0,event.startLocation.y))),b = CGPoint(x: min(size.width,max(0,event.location.x)),y: min(size.height,max(0,event.location.y)))
                    selection = CGRect(x: min(a.x,b.x),y: min(a.y,b.y),width: abs(a.x-b.x),height: abs(a.y-b.y))
                }.onEnded { _ in
                    if let selection,size.width>0,size.height>0,selection.width>=1,selection.height>=1 { crop([selection.minX/size.width,selection.minY/size.height,selection.width/size.width,selection.height/size.height]) };selection = nil
                }).accessibilityLabel("Glyph crop canvas. Crop and baseline fields provide keyboard control.")
            }.frame(width: geometry.size.width,height: geometry.size.height,alignment: .center)
        }
    }
}
