import SwiftUI
import UniformTypeIdentifiers

struct GraphicStudioView: View {
    @Bindable var controller: GraphicStudioController
    @State private var newName = "My graphic"
    @State private var kind = GraphicScene.Kind.particles
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 24) {
                ClautoSection("Graphics studio",detail: "Build an illustration from editable models, then add your cutouts and custom type. Inputs, assumptions and exported revisions stay with this project.") {
                    HStack(alignment: .bottom) {
                        ClautoField(label: "Scene name",text: $newName,placeholder: "Name this scene")
                        ClautoChoice(title: "Start with",selection: $kind,options: GraphicScene.Kind.allCases.map { ($0,$0.title) })
                        ClautoAction("Create graphic",icon: .add,kind: .primary) { controller.create(kind: kind,label: newName) }.disabled(controller.hasPendingWork)
                    }
                    if !controller.scenes.isEmpty {
                        ClautoChoice(title: "Saved scenes",selection: Binding(get: { controller.draft?.id ?? controller.scenes[0].id },set: controller.open),options: controller.scenes.map { ($0.id,$0.label+" · "+$0.kind.title) }).disabled(controller.hasPendingWork)
                        if controller.draft == nil { ClautoAction("Open scene") { controller.open(controller.scenes[0].id) } }
                    }
                }
                if let busy = controller.busy { HStack { ClautoActivity(label: busy);ClautoAction("Cancel",kind: .quiet) { controller.cancel() } } }
                if let issue = controller.issue { Text(issue).foregroundStyle(ClautoDesign.ember).textSelection(.enabled) }
                if controller.conflict { ClautoAction("Keep both scenes") { controller.keepBoth() } }
                if let draft = controller.draft {
                    ClautoSection(draft.label) {
                        HStack {
                            ClautoAction("Undo") { controller.undoChange() }.disabled(!controller.canUndo)
                            ClautoAction("Redo") { controller.redoChange() }.disabled(!controller.canRedo)
                            Spacer();Text(controller.saving ? "Saving…":controller.dirty ? "Saving changes…":"Saved with project").font(ClautoDesign.caption)
                        }
                        ClautoField(label: "Scene name",text: Binding(get: { controller.draft?.label ?? draft.label },set: { text in controller.changeScene(draft.id) { $0.label = text } }),placeholder: "Name this scene")
                        ClautoChoice(title: "Model",selection: Binding(get: { controller.draft?.scene.kind ?? draft.scene.kind },set: { controller.setKind($0,sceneID: draft.id) }),options: GraphicScene.Kind.allCases.map { ($0,$0.title) })
                        Text(draft.scene.validationLabel).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                        HStack {
                            number("Width",value: Double(draft.scene.width)) { value in controller.changeScene(draft.id) { $0.scene.width = Int(value) } }
                            number("Height",value: Double(draft.scene.height)) { value in controller.changeScene(draft.id) { $0.scene.height = Int(value) } }
                            number("Frames · 23.976 fps",value: Double(draft.scene.frameCount)) { value in controller.setFrameCount(Int(value),sceneID: draft.id) }
                        }
                        GraphicModelControls(controller: controller,scene: draft.scene).id(draft.id)
                    }.disabled(controller.busy != nil)
                    ClautoSection("Preview",detail: "Transparency is shown against paper. The assumptions label is part of every exported frame.") {
                        ZStack {
                            Rectangle().fill(ClautoDesign.paper)
                            if let raster = controller.preview,let image = try? CutoutImageIO.image(raster) { Image(decorative: image,scale: 1).resizable().aspectRatio(contentMode: .fit).accessibilityLabel("Rendered graphic preview") }
                            else { Text("Your scene will appear here as its inputs become ready.").foregroundStyle(ClautoDesign.quiet).padding() }
                        }.frame(height: 360).clipped()
                        HStack {
                            Slider(value: Binding(get: { Double(controller.previewFrame) },set: { controller.previewFrame = min(draft.scene.frameCount-1,Int($0)) }),in: 0...Double(max(1,draft.scene.frameCount-1)),step: 1).accessibilityLabel("Preview frame")
                            Text("Frame \(controller.previewFrame+1) / \(draft.scene.frameCount)").font(ClautoDesign.caption).monospacedDigit()
                        }
                        if controller.previewing { ClautoActivity(label: "Updating preview…") }
                        if let issue = controller.previewIssue { Text(issue).foregroundStyle(ClautoDesign.ember).textSelection(.enabled) }
                    }
                    GraphicLayerControls(controller: controller,scene: draft.scene).disabled(controller.busy != nil)
                    ClautoSection("Export this graphic",detail: "Creates a transparent ProRes 4444 movie and a movable Final Cut graphic layer. Editable scene inputs, exact cutout/font files and verification accompany every revision.") {
                        ClautoAction("Render & export",icon: .check,kind: .primary) { controller.exportScene(sceneID: draft.id) }.disabled(controller.busy != nil || controller.previewIssue != nil || controller.previewing)
                        if controller.busy != nil,controller.exportProgress>0 { ProgressView(value: controller.exportProgress).accessibilityLabel("Graphics export progress") }
                        if let result = controller.exported {
                            Text("\(result.revision.proof.frameCount) verified frames · ProRes 4444 · transparent alpha").font(ClautoDesign.caption)
                            HStack {
                                ClautoAction("Reveal movie",icon: .folder) { NSWorkspace.shared.activateFileViewerSelecting([result.movieURL]) }
                                ClautoAction("Reveal Final Cut layer") { NSWorkspace.shared.activateFileViewerSelecting([result.timelineURL]) }
                            }
                            Text("The Final Cut layer can be moved, trimmed and transformed. Edit the model, text or cutout inputs here and export another revision to change its pixels.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                        }
                    }
                    ClautoSection("Assumptions & review",detail: "Each assumption appears in the rendered footer. Review notes remain in the editable scene.") {
                        ForEach(draft.scene.assumptions) { assumption in
                            HStack {
                                ClautoField(label: "Assumption",text: Binding(get: { assumption.text },set: { text in controller.updateAssumption(sceneID: draft.id,id: assumption.id,text: text) }),placeholder: "State this model assumption")
                                ClautoAction("Remove") { controller.changeScene(draft.id) { $0.scene.assumptions.removeAll { $0.id==assumption.id } } }
                            }
                        }
                        ClautoAction("Add assumption") { controller.changeScene(draft.id) { $0.scene.assumptions.append(.init(text: "Describe this model assumption")) } }.disabled(draft.scene.assumptions.count>=32)
                        ClautoTextArea(text: Binding(get: { controller.draft?.scene.reviewNotes ?? "" },set: { text in controller.changeScene(draft.id) { $0.scene.reviewNotes = text } }),label: "Review notes").frame(height: 95)
                    }.disabled(controller.busy != nil)
                }
            }.padding(28).frame(maxWidth: 1250,alignment: .leading)
        }.task { await controller.load();controller.refreshPreview() }.onDisappear { controller.suspendPreview() }
    }
    private func number(_ title: String,value: Double,set: @escaping (Double) -> Void) -> some View { GraphicNumberField(title: title,value: value,set: set) }
}

private extension GraphicScene.Kind {
    var title: String { switch self { case .particles:"Particle physics";case .molecule:"Molecule";case .atom:"Atom illustration";case .reaction:"Reaction diagram";case .object:"3D object";case .market:"Supply & demand" } }
}
private struct GraphicNumberField: View {
    let title: String
    let value: Double
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading,spacing: 4) {
            Text(title).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            TextField(title,text: $text).textFieldStyle(.plain).font(ClautoDesign.body).foregroundStyle(ClautoDesign.ink)
                .padding(11).background(ClautoDesign.sheet)
                .overlay(Rectangle().stroke(focused ? ClautoDesign.ink:ClautoDesign.rule,lineWidth: focused ? 2:1))
                .focused($focused).focusEffectDisabled().accessibilityLabel(title)
            if Double(text).map({ !$0.isFinite || abs($0)>1_000_000 }) ?? true { Text("Enter a finite number.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
            else if Double(text) != value { Text("Not applied yet. Use a value inside this model's range.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
        }.onAppear { text = String(value) }.onChange(of: value) { _,value in if !focused { text = String(value) } }.onChange(of: text) { _,text in
            if let number = Double(text),number.isFinite,abs(number)<=1_000_000,number != value { set(number) }
        }.onChange(of: focused) { _,focused in if !focused { text = String(value) } }
    }
}
private struct GraphicModelControls: View {
    @Bindable var controller: GraphicStudioController
    let scene: GraphicScene
    private func number(_ title: String,_ value: Double,_ edit: @escaping (inout GraphicScene,Double) -> Void) -> some View {
        GraphicNumberField(title: title,value: value) { number in controller.changeScene(scene.id,kind: scene.kind) { edit(&$0.scene,number) } }
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            if let model = scene.particles {
                HStack { number("Particles · 1–64",Double(model.count)) { $0.particles!.count = Int($1) };number("Seed · positive integer",Double(model.seed)) { $0.particles!.seed = UInt64(max(1,$1)) } }
                HStack { number("Gravity",model.gravity) { $0.particles!.gravity = $1 };number("Restitution · 0–1",model.restitution) { $0.particles!.restitution = $1 };number("Initial speed",model.speed) { $0.particles!.speed = $1 } }
                HStack { number("Disk radius",model.radius) { $0.particles!.radius = $1 };number("Box width",model.width) { $0.particles!.width = $1 };number("Box height",model.height) { $0.particles!.height = $1 } }
            }
            if let model = scene.atom {
                HStack { number("Protons · 1–118",Double(model.protonCount)) { $0.atom!.protonCount = Int($1) };number("Electrons · 0–32",Double(model.electronCount)) { $0.atom!.electronCount = Int($1) } }
                HStack { number("Orbit radius",model.orbitRadius) { $0.atom!.orbitRadius = $1 };number("Radians / second",model.radiansPerSecond) { $0.atom!.radiansPerSecond = $1 } }
            }
            if let model = scene.market {
                HStack { number("Demand intercept",model.demandIntercept) { $0.market!.demandIntercept = $1 };number("Demand slope",model.demandSlope) { $0.market!.demandSlope = $1 } }
                HStack { number("Supply intercept",model.supplyIntercept) { $0.market!.supplyIntercept = $1 };number("Supply slope",model.supplySlope) { $0.market!.supplySlope = $1 } }
                HStack { number("Demand shift / second",model.demandShiftPerSecond) { $0.market!.demandShiftPerSecond = $1 };number("Maximum quantity",model.maximumQuantity) { $0.market!.maximumQuantity = $1 };number("Maximum price",model.maximumPrice) { $0.market!.maximumPrice = $1 } }
            }
            if let model = scene.object {
                HStack { ClautoAction("Import OBJ geometry",icon: .folder) { let panel = NSOpenPanel();panel.canChooseDirectories = false;panel.allowsMultipleSelection = false;panel.allowedContentTypes = [UTType(filenameExtension: "obj") ?? .data];panel.begin { if $0 == .OK,let url = panel.url { controller.importOBJ(url,sceneID: scene.id) } } };ClautoAction("Use cube") { controller.useCube(sceneID: scene.id) } }
                Text(controller.draft?.objectSource?.name ?? "Parametric cube").font(ClautoDesign.caption)
                Text("\(model.vertices.count) vertices · \(model.triangles.count) triangles. Vertex-only, planar convex OBJ faces; no external materials or textures.").font(ClautoDesign.caption)
                number("Spin · radians / second",model.spinRadiansPerSecond) { $0.object!.spinRadiansPerSecond = $1 }
                GraphicColorPicker(title: "Object color",value: model.color) { value in controller.changeScene(scene.id,kind: scene.kind) { $0.scene.object!.color = value } }
            }
            if let model = scene.molecule {
                number("Spin · radians / second",model.spinRadiansPerSecond) { $0.molecule!.spinRadiansPerSecond = $1 }
                ForEach(model.atoms) { atom in
                    HStack {
                        Text("Atom \(atom.id)").font(ClautoDesign.caption)
                        ClautoChoice(title: "Element",selection: Binding(get: { atom.element },set: { text in controller.changeScene(scene.id,kind: scene.kind) { if let i = $0.scene.molecule?.atoms.firstIndex(where: { $0.id==atom.id }) { $0.scene.molecule!.atoms[i].element = text } } }),options: GraphicElements.symbols.sorted().map { ($0,$0) })
                        ForEach(0..<3,id: \.self) { axis in
                            number(["X","Y","Z"][axis],[atom.position.x,atom.position.y,atom.position.z][axis]) { scene,value in
                                guard let i = scene.molecule?.atoms.firstIndex(where: { $0.id==atom.id }) else { return }
                                switch axis { case 0:scene.molecule!.atoms[i].position.x = value;case 1:scene.molecule!.atoms[i].position.y = value;default:scene.molecule!.atoms[i].position.z = value }
                            }
                        }
                        ClautoAction("Remove") { controller.changeScene(scene.id,kind: scene.kind) { $0.scene.molecule!.atoms.removeAll { $0.id==atom.id };$0.scene.molecule!.bonds.removeAll { $0.first==atom.id || $0.second==atom.id } } }.disabled(model.atoms.count==1)
                    }
                }
                ClautoAction("Add carbon atom") { controller.changeScene(scene.id,kind: scene.kind) { let id = ($0.scene.molecule!.atoms.map(\.id).max() ?? 0)+1;$0.scene.molecule!.atoms.append(.init(id: id,element: "C",position: .init(x: 0,y: 0),radius: 0.32,color: .sage)) } }
                ForEach(model.bonds) { bond in
                    HStack {
                        GraphicNumberField(title: "Bond from atom",value: Double(bond.first)) { value in controller.updateBond(sceneID: scene.id,bondID: bond.id) { $0.first = Int(value) } }
                        GraphicNumberField(title: "To atom",value: Double(bond.second)) { value in controller.updateBond(sceneID: scene.id,bondID: bond.id) { $0.second = Int(value) } }
                        GraphicNumberField(title: "Order · 1–3",value: Double(bond.order)) { value in controller.updateBond(sceneID: scene.id,bondID: bond.id) { $0.order = Int(value) } }
                        ClautoAction("Remove bond") { controller.changeScene(scene.id,kind: scene.kind) { $0.scene.molecule!.bonds.removeAll { $0.id==bond.id } } }
                    }
                }
                ClautoAction("Add bond") { controller.changeScene(scene.id,kind: scene.kind) { value in
                    guard let model = value.scene.molecule else { return }
                    for a in model.atoms { for b in model.atoms where a.id<b.id {
                        if !model.bonds.contains(where: { Set([$0.first,$0.second])==Set([a.id,b.id]) }) { value.scene.molecule!.bonds.append(.init(first: a.id,second: b.id));return }
                    } }
                } }.disabled(model.atoms.count<2)
            }
            if let model = scene.reaction {
                ForEach([false,true],id: \.self) { products in
                    Text(products ? "Products":"Reactants").font(ClautoDesign.body)
                    let terms = products ? model.products:model.reactants
                    ForEach(terms) { term in
                        HStack {
                            GraphicNumberField(title: "Coefficient",value: Double(term.coefficient)) { value in controller.updateReactionTerm(sceneID: scene.id,termID: term.id,products: products) { $0.coefficient = Int(value) } }
                            GraphicFormulaField(observation: controller.formulaObservation(sceneID: scene.id,termID: term.id,products: products)) { submission in controller.updateReactionTerm(sceneID: scene.id,termID: term.id,products: products,submission: submission) { $0.atoms = submission.atoms } }.id(term.id)
                            ClautoAction("Remove term") { controller.changeScene(scene.id,kind: scene.kind) { if products { $0.scene.reaction!.products.removeAll { $0.id==term.id } } else { $0.scene.reaction!.reactants.removeAll { $0.id==term.id } } } }.disabled(terms.count==1)
                        }
                    }
                    ClautoAction("Add term") { controller.changeScene(scene.id,kind: scene.kind) { if products { $0.scene.reaction!.products.append(.init(coefficient: 1,atoms: ["H":2])) } else { $0.scene.reaction!.reactants.append(.init(coefficient: 1,atoms: ["H":2])) } } }
                }
                number("Rearrangement duration · seconds",model.durationSeconds) { $0.reaction!.durationSeconds = $1 }
                Text("Atom counts must balance before rendering. This illustrates conservation; it does not predict chemistry, kinetics or safety.").font(ClautoDesign.caption)
            }
        }
    }
}
private struct GraphicFormulaField: View {
    let observation: GraphicFormulaObservation
    let apply: (GraphicFormulaSubmission) -> Void
    @State private var state: GraphicFormulaEditorState
    @State private var issue: String?
    init(observation: GraphicFormulaObservation,apply: @escaping (GraphicFormulaSubmission) -> Void) {
        self.observation = observation;self.apply = apply;_state = State(initialValue: .init(atoms: observation.atoms,revision: observation.revision,historyEpoch: observation.historyEpoch))
    }
    var body: some View {
        VStack(alignment: .leading) {
            ClautoField(label: "Formula",text: $state.text,placeholder: "H2O").onSubmit { do { apply(state.submission(try GraphicElements.parseFormula(state.text)));issue = nil } catch { issue = error.localizedDescription } }
            if let issue { Text(issue).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
            else if (try? GraphicElements.parseFormula(state.text)) != observation.atoms { Text("This formula is not applied yet. Correct it to update the saved model and preview.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember) }
        }.onChange(of: observation) { _,value in state.reconcile(value);issue = nil }.onChange(of: state.text) { _,text in if let value = try? GraphicElements.parseFormula(text) { apply(state.submission(value));issue = nil } }
    }
}

private struct GraphicLayerControls: View {
    @Bindable var controller: GraphicStudioController
    let scene: GraphicScene
    @State private var cutoutID: UUID?
    var body: some View {
        ClautoSection("Cutouts & text",detail: "Each layer selects an immutable project revision. Changes in Cutout or Font Studio never silently replace a scene's earlier inputs.") {
            HStack {
                ClautoAction("Add text",icon: .add) { controller.addText(sceneID: scene.id) }
                ClautoAction("Refresh project assets") { Task { await controller.load() } }
                if let first = controller.cutoutChoices.first {
                    ClautoChoice(title: "Extracted PNG",selection: Binding(get: { cutoutID ?? first.id },set: { cutoutID = $0 }),options: controller.cutoutChoices.map { ($0.id,$0.name) })
                    ClautoAction("Add cutout") { if let choice = controller.cutoutChoices.first(where: { $0.id==(cutoutID ?? first.id) }) { controller.addCutout(choice,sceneID: scene.id) } }
                }
            }
            if controller.cutoutChoices.isEmpty { Text("Export a PNG in Cutout Studio to make it available here.").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet) }
            ForEach(scene.imageLayers) { layer in
                ClautoDisclosure("Cutout · "+(controller.cutoutChoices.first(where: { $0.id==layer.revisionID })?.name ?? String(layer.cutoutID.uuidString.prefix(8)))) {
                    GraphicTransformControls(transform: layer.transform,frames: scene.frameCount) { transform in controller.changeScene(scene.id,kind: scene.kind) { if let i = $0.scene.imageLayers.firstIndex(where: { $0.id==layer.id }) { $0.scene.imageLayers[i].transform = transform } } }
                    ClautoAction("Remove cutout",kind: .quiet) { controller.changeScene(scene.id,kind: scene.kind) { $0.scene.imageLayers.removeAll { $0.id==layer.id } } }
                }
            }
            ForEach(scene.textLayers) { layer in
                ClautoDisclosure("Text · "+String(layer.text.prefix(50))) {
                    ClautoField(label: "Words",text: Binding(get: { layer.text },set: { text in edit(layer.id) { $0.text = text } }),placeholder: "Your words")
                    let current = layer.font?.revisionID.uuidString ?? "bundled"
                    let available = [("bundled","Bundled Work Sans")]+controller.fontChoices.map { ($0.id.uuidString,$0.name) }
                    let options = available.contains(where: { $0.0==current }) ? available:available+[(current,"Retained earlier font revision")]
                    ClautoChoice(title: "Typeface",selection: Binding(get: { current },set: { value in
                        if value=="bundled" { edit(layer.id) { $0.font = nil } }
                        else if let choice = controller.fontChoices.first(where: { $0.id.uuidString==value }) { edit(layer.id) { $0.font = .init(fontID: choice.fontID,revisionID: choice.id,ttfSHA256: choice.ttfSHA256) } }
                    }),options: options)
                    GraphicColorPicker(title: "Text color",value: layer.color) { value in edit(layer.id) { $0.color = value } }
                    GraphicNumberField(title: "Font size · fraction of canvas height",value: layer.fontSize) { value in edit(layer.id) { $0.fontSize = value } }
                    GraphicTransformControls(transform: layer.transform,frames: scene.frameCount) { value in edit(layer.id) { $0.transform = value } }
                    ClautoAction("Remove text",kind: .quiet) { controller.changeScene(scene.id,kind: scene.kind) { $0.scene.textLayers.removeAll { $0.id==layer.id } } }
                }
            }
        }
    }
    private func edit(_ id: UUID,_ work: (inout GraphicTextLayer) -> Void) {
        controller.changeScene(scene.id,kind: scene.kind) { if let i = $0.scene.textLayers.firstIndex(where: { $0.id==id }) { work(&$0.scene.textLayers[i]) } }
    }
}
private struct GraphicTransformControls: View {
    let transform: GraphicLayerTransform
    let frames: Int
    let set: (GraphicLayerTransform) -> Void
    private func number(_ title: String,_ path: WritableKeyPath<GraphicLayerTransform,Double>) -> some View {
        GraphicNumberField(title: title,value: transform[keyPath: path]) { value in var next = transform;next[keyPath: path] = value;set(next) }
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            HStack { number("Center X · 0–1",\.x);number("Center Y · 0–1",\.y);number("Rotation · degrees",\.rotationDegrees) }
            HStack { number("Width · canvas fraction",\.width);number("Height · canvas fraction",\.height);number("Opacity · 0–1",\.opacity) }
            HStack {
                GraphicNumberField(title: "First frame · starts at 0",value: Double(transform.startFrame)) { value in var next = transform;next.startFrame = Int(value);set(next) }
                GraphicNumberField(title: "End frame · exclusive",value: Double(transform.endFrame ?? frames)) { value in var next = transform;next.endFrame = Int(value);set(next) }
            }
        }
    }
}

private struct GraphicColorPicker: View {
    let title: String
    let value: GraphicColor
    let set: (GraphicColor) -> Void
    var body: some View {
        ColorPicker(title,selection: Binding(get: { Color(.sRGB,red: value.r,green: value.g,blue: value.b,opacity: value.a) },set: { selected in
            if let color = NSColor(selected).usingColorSpace(.sRGB) { set(.init(r: Double(color.redComponent),g: Double(color.greenComponent),b: Double(color.blueComponent),a: Double(color.alphaComponent))) }
        }),supportsOpacity: true)
    }
}
