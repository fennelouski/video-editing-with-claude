import SwiftUI
import UniformTypeIdentifiers

struct CutoutStudioView: View {
    @Bindable var controller: CutoutStudioController
    @State private var gesturePoints: [CutoutPoint] = []
    @State private var keyboardX = "50"
    @State private var keyboardY = "50"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 22) {
                ClautoSection("Cutout studio",detail: "Keep the subject, paint an edge, then save a transparent PNG. Originals and every exported revision stay on this project's drive.") {
                    HStack {
                        ClautoAction("Choose image",icon: .add,kind: .primary) { chooseImage(mask: false) }.disabled(controller.hasPendingWork)
                        ClautoAction("Retry saving") { Task { _ = await controller.saveNow() } }.disabled(!controller.dirty || controller.saving || controller.exporting)
                        if controller.saving { Text("Saving correction…").font(ClautoDesign.caption) }
                    }
                    if !controller.assets.isEmpty {
                        ClautoChoice(title: "Saved cutout sources",selection: Binding(get: { controller.saved?.source.id ?? controller.assets[0].id },set: { controller.open($0) }),options: controller.assets.map { ($0.id,$0.name) }).disabled(controller.hasPendingWork)
                        if controller.saved == nil { ClautoAction("Open selected source") { controller.open(controller.assets[0].id) } }
                    }
                }
                if let busy = controller.busy {
                    HStack { ClautoActivity(label: busy); ClautoAction("Cancel",kind: .quiet) { controller.cancel() } }
                }
                if let issue = controller.issue {
                    Text(issue).foregroundStyle(ClautoDesign.ember).textSelection(.enabled).accessibilityIdentifier("cutoutIssue")
                }
                if controller.hasUnfinishedImport && controller.busy == nil {
                    HStack {
                        ClautoAction("Retry original copy") { controller.retryImport() }
                        ClautoAction("Choose a different image",kind: .quiet) { controller.abandonImport() }
                    }
                }
                if controller.conflict {
                    ClautoAction("Keep both corrections",kind: .primary) { controller.keepBoth() }
                    Text("This window's correction becomes a separate asset. The other saved correction and all earlier PNGs remain available.").font(ClautoDesign.caption)
                }
                if let source = controller.source, let draft = controller.draft {
                    HStack(alignment: .top,spacing: 22) {
                        VStack(alignment: .leading,spacing: 10) {
                            Text("Paint on the original").font(ClautoDesign.type(16,weight: .semibold))
                            raster(source,editable: true).aspectRatio(CGFloat(source.width)/CGFloat(source.height),contentMode: .fit)
                            Text("Drag to restore or erase. Coordinates follow the oriented image; only the mask changes.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                        }
                        VStack(alignment: .leading,spacing: 10) {
                            Text("Transparent result").font(ClautoDesign.type(16,weight: .semibold))
                            if let preview = controller.preview { raster(preview,editable: false).aspectRatio(CGFloat(preview.width)/CGFloat(preview.height),contentMode: .fit) }
                            else { Text("Choose a subject or paint the area to keep.").frame(maxWidth: .infinity,minHeight: 180).background(ClautoDesign.soft) }
                            Text("The checkerboard means transparent. Color is converted to the editable sRGB working format; the original encoded image stays intact.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                        }
                    }
                    ClautoSection("Choose & correct") {
                        HStack {
                            ClautoAction("Find subjects locally") { controller.detectSubjects() }.disabled(controller.busy != nil)
                            ClautoAction("Use a mask image") { chooseImage(mask: true) }.disabled(controller.busy != nil)
                        }
                        if !controller.subjects.isEmpty {
                            HStack {
                                ForEach(controller.subjects,id: \.self) { id in
                                    ClautoToggle(title: "Subject \(id)",isOn: Binding(get: { controller.draft?.recipe.selectedSubjects.contains(id) == true },set: { _ in controller.selectSubject(id) }))
                                }
                            }
                        }
                        HStack {
                            ClautoChoice(title: "Brush",selection: $controller.brushMode,options: [(.restore,"Keep subject"),(.erase,"Erase background")])
                            ClautoChoice(title: "Edge feather",selection: Binding(get: { draft.recipe.featherPixels },set: { value in controller.change { $0.recipe.featherPixels = value } }),options: [0,1,2,4,8,16].map { ($0,"\($0) pixels") })
                            ClautoAction("Undo") { controller.undoCorrection() }.disabled(!controller.canUndo)
                            ClautoAction("Redo") { controller.redoCorrection() }.disabled(!controller.canRedo)
                        }
                        HStack {
                            Text("Brush radius: \(Int(controller.brushRadius)) px").font(ClautoDesign.caption)
                            Slider(value: $controller.brushRadius,in: 0.5...Double(max(source.width,source.height))).accessibilityLabel("Brush radius in source pixels")
                        }
                        ClautoDisclosure("Paint with coordinates") {
                            HStack {
                                ClautoField(label: "X percent",text: $keyboardX,placeholder: "0–100")
                                ClautoField(label: "Y percent",text: $keyboardY,placeholder: "0–100")
                                ClautoAction("Paint point") {
                                    guard let x = Double(keyboardX), let y = Double(keyboardY), x.isFinite, y.isFinite, (0...100).contains(x), (0...100).contains(y) else { return }
                                    controller.addStroke([.init(x: x/100,y: y/100)])
                                }
                            }
                        }
                        ClautoAction("Save transparent PNG",icon: .check,kind: .primary) { controller.exportPNG() }.disabled(controller.busy != nil || controller.preview == nil)
                        if let url = controller.exportedURL {
                            Text("Saved \(url.lastPathComponent) in revision \(url.deletingLastPathComponent().lastPathComponent). This is a local extracted image, not a scanned animation-variant set.").font(ClautoDesign.caption).textSelection(.enabled)
                            ClautoAction("Show saved PNG",icon: .folder,kind: .quiet) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1280,alignment: .leading)
        }.task { await controller.load() }
    }
    @ViewBuilder private func raster(_ value: CutoutRaster,editable: Bool) -> some View {
        if let image = try? CutoutImageIO.image(value) {
            GeometryReader { geometry in
                ZStack {
                    Canvas { context,size in
                        context.fill(Path(CGRect(origin: .zero,size: size)),with: .color(.white))
                        for y in stride(from: CGFloat(0),to: size.height,by: 16) {
                            for x in stride(from: CGFloat(0),to: size.width,by: 16) where (Int(x/16)+Int(y/16))%2 == 0 {
                                context.fill(Path(CGRect(x: x,y: y,width: 16,height: 16)),with: .color(.gray.opacity(0.22)))
                            }
                        }
                    }.accessibilityHidden(true)
                    Image(decorative: image,scale: 1).resizable().interpolation(.high)
                    if editable {
                        Rectangle().fill(.clear).contentShape(Rectangle()).gesture(
                            DragGesture(minimumDistance: 0).onChanged { event in
                                guard geometry.size.width > 0, geometry.size.height > 0, gesturePoints.count < 1024 else { return }
                                let point = CutoutPoint(x: Double(min(1,max(0,event.location.x/geometry.size.width))),y: Double(min(1,max(0,event.location.y/geometry.size.height))))
                                if gesturePoints.last != point { gesturePoints.append(point) }
                            }.onEnded { _ in if !gesturePoints.isEmpty { controller.addStroke(gesturePoints) }; gesturePoints = [] }
                        ).accessibilityLabel("Cutout brush canvas. Use Paint with coordinates for keyboard correction.")
                    }
                }
            }.accessibilityLabel(editable ? "Original source image":"Transparent cutout preview")
        }
    }
    private func chooseImage(mask: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.tiff,.heic]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if mask { controller.importMaskFile(url) } else { controller.importFile(url) }
        }
    }
}
