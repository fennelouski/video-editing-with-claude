import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@Suite(.serialized) struct GraphicIntegrationTests {
    private func fixture() async throws -> (URL,Project,URL) {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-graphic-integration-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        return (root,try await ProjectRepository().create(name: "Synthetic graphics integration",root: root,engine: engine),engine)
    }
    @MainActor private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic graphics integration condition timed out")
    }
    @Test func sceneDraftCASAndOriginalOBJSurviveConflictingInputsAndReopen() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository(),id = UUID(),initial = try await repo.create(project,id: id,label: "Synthetic object",scene: .preset(.object))
        let bytes = Data("v -1 -1 0\nv 1 -1 0\nv 0 1 0\nf 1 2 3\n".utf8)
        let (source,mesh) = try await repo.importOBJ(project,sceneID: id,id: UUID(),name: "synthetic.obj",bytes: bytes)
        var draft = initial.draft;draft.scene.object = mesh;draft.objectSource = source
        let saved = try await repo.save(project,base: initial,draft: draft)
        var stale = initial.draft;stale.label = "A stale writer"
        await #expect(throws: (any Error).self) { _ = try await repo.save(project,base: initial,draft: stale) }
        #expect(try await repo.load(project,id: id)==saved)
        let original = project.folder.appendingPathComponent("assets/generated-scenes/\(id)/sources/\(source.id)/original.obj")
        #expect(try Data(contentsOf: original)==bytes)
        try Data("changed".utf8).write(to: original);var changed = saved.draft;changed.label = "Retry after corruption"
        await #expect(throws: (any Error).self) { _ = try await repo.save(project,base: saved,draft: changed) }
        #expect(try await repo.load(project,id: id)==saved)
    }
    @Test func extractedPNGRevisionIsVerifiedAndActuallyCompositedWithTimingOpacityAndTransparency() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = CutoutRepository(),id = UUID(),original = try CutoutImageIO.png(.init(width: 32,height: 32,rgba: Data((0..<1024).flatMap { _ in [UInt8(255),0,0,255] })))
        var cut = try await repo.create(project,id: id,createdMilliseconds: 1,name: "Synthetic red.png",bytes: original)
        var draft = cut.draft;draft.recipe.strokes = [.init(mode: .restore,radiusPixels: 8,points: [.init(x: 0.5,y: 0.5)])]
        cut = try await repo.save(project,base: cut,draft: draft)
        let result = try await repo.export(project,snapshot: cut,id: UUID(),created: Date()),png = try Data(contentsOf: result.pngURL)
        var scene = GraphicScene.preset(.object);scene.width = 640;scene.height = 360;scene.frameCount = 12
        let transform = GraphicLayerTransform(x: 0.8,y: 0.3,width: 0.2,height: 0.2,rotationDegrees: 30,opacity: 0.5,startFrame: 0,endFrame: 4)
        let layer = GraphicImageLayer(cutoutID: id,revisionID: result.revision.id,imageSHA256: TranscriptSourceMap.sha(png),transform: transform);scene.imageLayers = [layer]
        let assets = try await GraphicAssetResolver().resolve(scene,project: project),renderer = GraphicSceneRenderer()
        #expect(assets.files[layer.id.uuidString+".png"]==png)
        await #expect(throws: (any Error).self) { _ = try await GraphicAssetResolver(byteLimit: 10).resolve(scene,project: project) }
        await #expect(throws: (any Error).self) { _ = try await GraphicAssetResolver(pixelLimit: 10).resolve(scene,project: project) }
        let choices = try await GraphicAssetResolver().choices(project)
        #expect(choices.cutouts.first?.id==result.revision.id)
        let shown = try await renderer.render(scene,frame: 0,assets: assets),hidden = try await renderer.render(scene,frame: 6,assets: assets),i = (108*640+512)*4
        #expect(shown.rgba[i]>240 && shown.rgba[i+1]<10 && (126...129).contains(shown.rgba[i+3]))
        #expect(hidden.rgba[i+3]==0 && shown.rgba[3]==0)
        #expect(try Data(contentsOf: result.pngURL)==png)
        try Data("changed PNG".utf8).write(to: result.pngURL)
        await #expect(throws: (any Error).self) { _ = try await GraphicAssetResolver().resolve(scene,project: project) }
    }
    @MainActor @Test func chosenImmutableCustomFontActuallyDrawsAndMissingCharactersCannotUseSystemFallback() async throws {
        let (root,project,engine) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let font = FontStudioController(project: project,engine: engine)
        font.create(label: "Synthetic graphic type");try await wait { font.saved != nil && font.busy == nil }
        font.addGeneratedMapping();let mapping = try #require(font.selectedMappingID)
        font.updateMapping(mapping) { $0.character = "S" };font.trace(mapping);try await wait { font.busy == nil }
        font.compileFont();try await wait { font.busy == nil }
        let exported = try #require(font.exported),oldBytes = try Data(contentsOf: exported.ttfURL)
        var scene = GraphicScene.preset(.object);scene.width = 640;scene.height = 360;scene.frameCount = 8
        let ref = GraphicFontReference(fontID: exported.revision.fontID,revisionID: exported.revision.id,ttfSHA256: exported.revision.ttfSHA256)
        scene.textLayers = [.init(text: "SS",font: ref,fontSize: 0.08,transform: .init(x: 0.2,y: 0.25,width: 0.2,height: 0.2))]
        let resolver = GraphicAssetResolver(),assets = try await resolver.resolve(scene,project: project),renderer = GraphicSceneRenderer(),withText = try await renderer.render(scene,frame: 0,assets: assets)
        var without = scene;without.textLayers = []
        #expect(try await renderer.render(without,frame: 0).rgba != withText.rgba)
        #expect(assets.files.values.contains(oldBytes) && assets.files.keys.contains(where: { $0.hasSuffix("-OFL.txt") }))
        scene.textLayers[0].text = "S?"
        await #expect(throws: (any Error).self) { _ = try await renderer.render(scene,frame: 0,assets: assets) }
        #expect(try Data(contentsOf: exported.ttfURL)==oldBytes)
        #expect(await font.flushForExit())
    }
    @MainActor @Test func sceneControllerRetainsIncompleteDraftAcrossSaveUndoAndConflictCopy() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository(),controller = GraphicStudioController(project: project,repository: repo)
        controller.create(kind: .reaction,label: "Unbalanced draft");try await wait { controller.saved != nil && controller.busy == nil }
        controller.change { $0.scene.reaction!.reactants[0].coefficient = 1 }
        #expect(await controller.saveNow())
        let saved = try #require(controller.saved)
        #expect(saved.draft.scene.reaction!.reactants[0].coefficient==1)
        #expect(throws: (any Error).self) { try saved.draft.scene.validate() }
        controller.undoChange();#expect(await controller.saveNow())
        #expect(controller.draft?.scene.reaction?.reactants[0].coefficient==2)
        let base = try #require(controller.saved);var other = base.draft;other.label = "Other window"
        _ = try await repo.save(project,base: base,draft: other)
        controller.change { $0.label = "Keep my correction" }
        #expect(!(await controller.saveNow()) && controller.conflict && controller.draft?.label=="Keep my correction")
        controller.keepBoth();try await wait { controller.busy == nil }
        let copy = try #require(controller.saved)
        #expect(copy.draft.id != base.draft.id && copy.draft.label=="Keep my correction")
        #expect(try await repo.load(project,id: base.draft.id).draft.label=="Other window")
        #expect(try await repo.load(project,id: copy.draft.id)==copy)
        #expect(await controller.flushForExit())
    }
    @Test func boundedGraphicsAdmissionWaitsAndCancellationKeepsPhysicalCapacityUntilWorkEnds() async throws {
        let gate = GraphicBlockingExecutor(label: "synthetic-graphics-admission",capacity: 1),hold = DispatchSemaphore(value: 0)
        let first = Task { try await gate.perform { _ in hold.wait();return 1 } }
        defer { hold.signal() }
        for _ in 0..<1000 { if gate.inFlight==1 { break };try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.inFlight==1)
        let waiting = Task { try await gate.perform { _ in 2 } }
        for _ in 0..<1000 { if gate.waiting==1 { break };try await Task.sleep(for: .milliseconds(1)) }
        waiting.cancel();await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(gate.waiting==0 && gate.inFlight==1)
        first.cancel();await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(gate.inFlight==1)
        let third = Task { try await gate.perform { _ in 3 } }
        hold.signal();#expect(try await third.value==3)
        for _ in 0..<1000 { if gate.inFlight==0 { break };try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.inFlight==0)
    }
    @Test func simultaneousGraphicRenderersAllFinishWithoutTransientCapacityFailure() async throws {
        var scene = GraphicScene.preset(.object);scene.width = 320;scene.height = 240;scene.frameCount = 1
        let value = scene
        let outputs = try await withThrowingTaskGroup(of: Data.self,returning: [Data].self) { group in
            for _ in 0..<6 { group.addTask { try await GraphicSceneRenderer().render(value,frame: 0).rgba } }
            var result: [Data] = [];for try await bytes in group { result.append(bytes) };return result
        }
        #expect(outputs.count==6 && outputs.allSatisfy { $0==outputs[0] })
    }

    @Test func actualSceneExportReopensWithExactInputsEditableFinalCutLayerAndPreservedPriorMovie() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository();var scene = GraphicScene.preset(.particles);scene.width = 320;scene.height = 240;scene.frameCount = 4
        let draft = try await repo.create(project,id: UUID(),label: "Synthetic & <graphic>",scene: scene),service = GraphicSceneExportService(repository: repo)
        let first = try await service.export(project,snapshot: draft),bytes = try Data(contentsOf: first.movieURL)
        #expect(first.becameCurrent && first.revision.proof.frameCount==4 && first.revision.proof.decodedEveryFrame && first.revision.proof.maximumEndpointAlphaError<=2)
        #expect(first.revision.files["annotation-font.ttf"] != nil && first.revision.files["annotation-OFL.txt"] != nil && first.revision.files["scene.json"]?.sha256==draft.savedSHA256)
        #expect(first.revision.metalShaderSHA256==GraphicMetalRenderer.shaderSHA256)
        let document = try XMLDocument(data: Data(contentsOf: first.timelineURL),options: .nodeLoadExternalEntitiesNever)
        #expect(try document.nodes(forXPath: "/fcpxml/library/event/project/sequence/spine/gap/asset-clip[@lane='1']").count==1)
        #expect(try document.nodes(forXPath: "/fcpxml/resources/format[@frameDuration='1001/24000s']").count==1)
        let rep = try #require(document.nodes(forXPath: "/fcpxml/resources/asset/media-rep").first as? XMLElement)
        #expect(rep.attribute(forName: "src")?.stringValue==first.movieURL.absoluteString)
        #expect(try await repo.currentExport(project,sceneID: draft.draft.id)?.revision==first.revision)
        var changed = first.snapshot.draft;changed.scene.particles!.seed = 2
        let saved = try await repo.save(project,base: first.snapshot,draft: changed),second = try await service.export(project,snapshot: saved)
        #expect(second.revision.parentRevisionID==first.revision.id && second.revision.id != first.revision.id)
        #expect(try Data(contentsOf: first.movieURL)==bytes)
        #expect(try await repo.currentExport(project,sceneID: draft.draft.id)?.revision==second.revision)
        try Data("replaced".utf8).write(to: second.movieURL)
        await #expect(throws: (any Error).self) { _ = try await repo.currentExport(project,sceneID: draft.draft.id) }
        #expect(try Data(contentsOf: first.movieURL)==bytes)
    }
    @Test func completedCapturedExportCannotReplaceANewerSceneSavedDuringRender() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository();var scene = GraphicScene.preset(.object);scene.width = 320;scene.height = 240;scene.frameCount = 2
        let snapshot = try await repo.create(project,id: UUID(),label: "Captured",scene: scene),assets = try await GraphicAssetResolver().resolve(snapshot.draft.scene,project: project)
        let job = try await repo.prepareExport(project,snapshot: snapshot,id: UUID(),assets: assets)
        let output = try await GraphicAnimationExporter().export(snapshot.draft.scene,assets: assets,to: job.folder)
        let verifier = GraphicMovieVerifier(),proof = try await verifier.verify(job.folder,scene: snapshot.draft.scene,output: output)
        let wrong = try CutoutImageIO.png(.init(width: 1,height: 1,rgba: Data([0,0,0,0])))
        await #expect(throws: (any Error).self) { _ = try await verifier.verify(job.folder,scene: snapshot.draft.scene,output: .init(movieURL: output.movieURL,movie: output.movie,firstPNG: wrong,finalPNG: wrong,frames: output.frames,durationValue: output.durationValue,durationScale: output.durationScale,codec: output.codec)) }
        var newer = snapshot.draft;newer.label = "Newer correction"
        let saved = try await repo.save(project,base: snapshot,draft: newer)
        let completed = try await repo.publishExport(project,job: job,output: output,proof: proof)
        #expect(!completed.becameCurrent && completed.snapshot==saved && FileManager.default.fileExists(atPath: completed.movieURL.path))
        #expect(try await repo.load(project,id: snapshot.draft.id)==saved)
        #expect(try await repo.currentExport(project,sceneID: snapshot.draft.id)==nil)
    }
    @MainActor @Test func normalControllerExportFlushAndReopenVerifyTheActualMovie() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let controller = GraphicStudioController(project: project)
        controller.create(kind: .object,label: "Controller export");try await wait { controller.saved != nil && controller.busy==nil }
        controller.change { $0.scene.width = 320;$0.scene.height = 240;$0.scene.frameCount = 2 }
        controller.exportScene();try await wait { controller.busy==nil }
        let exported = try #require(controller.exported),id = exported.revision.sceneID
        #expect(controller.saved?.draft.currentRevisionID==exported.revision.id && !controller.dirty)
        #expect(await controller.flushForExit())
        let reopened = GraphicStudioController(project: project);reopened.open(id);try await wait { reopened.saved != nil && reopened.busy==nil }
        #expect(reopened.exported?.revision==exported.revision && reopened.draft==controller.draft)
        #expect(await reopened.flushForExit())
    }

    @MainActor @Test func cancellationBeforeMovieCompletionDoesNotPublishARevisionOrLoseTheDraft() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository();var scene = GraphicScene.preset(.particles);scene.width = 320;scene.height = 240;scene.frameCount = 96
        let snapshot = try await repo.create(project,id: UUID(),label: "Cancelled graphic",scene: scene)
        let progress = GraphicTestProgress()
        let task = Task { try await GraphicSceneExportService(repository: repo).export(project,snapshot: snapshot) { done,_ in await progress.set(done) } }
        for _ in 0..<1000 { if await progress.value>0 { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(await progress.value>0);task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await repo.load(project,id: snapshot.draft.id)==snapshot)
        #expect(try await repo.currentExport(project,sceneID: snapshot.draft.id)==nil)
    }
    @Test func changedFrozenExportInputRefusesPublicationWithoutReplacingTheSavedDraft() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository();var scene = GraphicScene.preset(.object);scene.width = 320;scene.height = 240;scene.frameCount = 1
        let snapshot = try await repo.create(project,id: UUID(),label: "Frozen input",scene: scene),assets = try await GraphicAssetResolver().resolve(snapshot.draft.scene,project: project)
        let job = try await repo.prepareExport(project,snapshot: snapshot,id: UUID(),assets: assets)
        let output = try await GraphicAnimationExporter().export(snapshot.draft.scene,assets: assets,to: job.folder)
        let proof = try await GraphicMovieVerifier().verify(job.folder,scene: snapshot.draft.scene,output: output)
        try Data("replaced font".utf8).write(to: job.folder.url.appendingPathComponent("annotation-font.ttf"))
        await #expect(throws: (any Error).self) { _ = try await repo.publishExport(project,job: job,output: output,proof: proof) }
        #expect(try await repo.load(project,id: snapshot.draft.id)==snapshot)
        #expect(try await repo.currentExport(project,sceneID: snapshot.draft.id)==nil)
    }

    @MainActor @Test func removedOrRetypedSceneCallbacksCannotRetargetAnotherTermBondOrAssumption() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let controller = GraphicStudioController(project: project)
        controller.create(kind: .reaction,label: "Stable rows");try await wait { controller.saved != nil && controller.busy==nil }
        let sceneID = try #require(controller.draft?.id),first = try #require(controller.draft?.scene.reaction?.reactants.first),second = try #require(controller.draft?.scene.reaction?.reactants.last)
        let callback = { @MainActor in controller.updateReactionTerm(sceneID: sceneID,termID: first.id,products: false) { $0.atoms = ["C":1] } }
        controller.changeScene(sceneID,kind: .reaction) { $0.scene.reaction!.reactants.removeAll { $0.id==first.id } }
        callback();#expect(controller.draft?.scene.reaction?.reactants==[second])
        controller.undoChange();#expect(controller.draft?.scene.reaction?.reactants.first?.id==first.id)
        callback();#expect(controller.draft?.scene.reaction?.reactants.first?.atoms==["C":1])
        controller.undoChange();#expect(controller.draft?.scene.reaction?.reactants.first?.atoms==first.atoms)
        var display = GraphicFormulaEditorState(atoms: first.atoms);display.text = "CO2";display.reconcile(first.atoms)
        #expect(display.text==GraphicFormulaEditorState.display(first.atoms))
        display.reconcile(second.atoms);#expect(display.text=="O2")
        controller.setKind(.molecule,sceneID: sceneID)
        var invoked = false
        controller.changeScene(sceneID,kind: .reaction) { _ in invoked = true }
        callback();#expect(!invoked && controller.draft?.scene.kind == .molecule)
        let oldBond = try #require(controller.draft?.scene.molecule?.bonds.first)
        controller.changeScene(sceneID,kind: .molecule) { $0.scene.molecule!.bonds.removeAll { $0.id==oldBond.id } }
        let surviving = controller.draft?.scene.molecule?.bonds
        controller.updateBond(sceneID: sceneID,bondID: oldBond.id) { $0.order = 3 }
        #expect(controller.draft?.scene.molecule?.bonds==surviving)
        let a = GraphicAssumption(text: "First"),b = GraphicAssumption(text: "Second")
        controller.changeScene(sceneID) { $0.scene.assumptions = [a,b] }
        controller.changeScene(sceneID) { $0.scene.assumptions.removeAll { $0.id==a.id } }
        controller.updateAssumption(sceneID: sceneID,id: a.id,text: "Late words")
        #expect(controller.draft?.scene.assumptions==[b])
        #expect(await controller.saveNow());controller.create(kind: .atom,label: "Other scene");try await wait { controller.busy==nil }
        let latest = controller.draft
        controller.changeScene(sceneID,kind: .molecule) { _ in invoked = true }
        controller.updateAssumption(sceneID: sceneID,id: b.id,text: "Wrong scene")
        #expect(!invoked && controller.draft==latest)
        #expect(await controller.flushForExit())
    }
    @Test func formulaAcknowledgementsPreserveNewerTypingAndHistoryRestoresOverrideIt() throws {
        var field = GraphicFormulaEditorState(atoms: ["H":2])
        field.text = "H2O";let first = field.submission(try GraphicElements.parseFormula(field.text))
        field.text = "H2Ox"
        field.reconcile(.init(atoms: first.atoms,revision: 1,origin: first,historyEpoch: 0))
        #expect(field.text=="H2Ox")
        field.text = "CO2";let second = field.submission(try GraphicElements.parseFormula(field.text))
        field.text = "CO2("
        field.reconcile(.init(atoms: second.atoms,revision: 3,origin: second,historyEpoch: 0))
        field.reconcile(.init(atoms: first.atoms,revision: 2,origin: first,historyEpoch: 0))
        #expect(field.text=="CO2(")
        field.reconcile(.init(atoms: ["H":2],revision: 4,origin: nil,historyEpoch: 1))
        #expect(field.text=="H2")
        field.reconcile(.init(atoms: second.atoms,revision: 3,origin: second,historyEpoch: 0))
        #expect(field.text=="H2")
        let other = GraphicFormulaEditorState(atoms: ["O":2]).submission(["O":2])
        field.text = "H2("
        field.reconcile(.init(atoms: other.atoms,revision: 5,origin: other,historyEpoch: 1))
        #expect(field.text=="O2")
        field.text = "CO2";let afterReset = field.submission(["C":1,"O":2])
        field.text = "CO2("
        field.reconcile(.init(atoms: afterReset.atoms,revision: 7,origin: afterReset,historyEpoch: 2))
        #expect(field.text=="CO2(")
    }
    @MainActor @Test func formulaControllerOriginsSurviveUnrelatedEditsAndUndoRedoResetTheField() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let controller = GraphicStudioController(project: project)
        controller.create(kind: .reaction,label: "Formula acknowledgements");try await wait { controller.saved != nil && controller.busy==nil }
        let sceneID = try #require(controller.draft?.id),term = try #require(controller.draft?.scene.reaction?.reactants.first)
        let initial = controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false)
        var field = GraphicFormulaEditorState(atoms: initial.atoms,revision: initial.revision,historyEpoch: initial.historyEpoch)
        field.text = "H2O";let submission = field.submission(try GraphicElements.parseFormula(field.text))
        controller.updateReactionTerm(sceneID: sceneID,termID: term.id,products: false,submission: submission) { $0.atoms = submission.atoms }
        let acknowledgement = controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false)
        #expect(acknowledgement.origin==submission && acknowledgement.historyEpoch==initial.historyEpoch)
        field.text = "H2Ox";field.reconcile(acknowledgement);#expect(field.text=="H2Ox")
        controller.updateReactionTerm(sceneID: sceneID,termID: term.id,products: false) { $0.coefficient += 1 }
        let unrelated = controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false)
        field.reconcile(unrelated);#expect(field.text=="H2Ox" && unrelated.origin==submission)
        controller.undoChange()
        let coefficientUndo = controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false)
        controller.changeScene(sceneID) { $0.label = "Unrelated edit after Undo" }
        let afterUnrelated = controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false)
        field.reconcile(afterUnrelated);#expect(coefficientUndo.historyEpoch>initial.historyEpoch && afterUnrelated.historyEpoch==coefficientUndo.historyEpoch && field.text=="H2O")
        controller.undoChange() // Undo the unrelated label change first.
        controller.undoChange()
        field.reconcile(controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false))
        #expect(field.text==GraphicFormulaEditorState.display(term.atoms))
        field.reconcile(acknowledgement);#expect(field.text==GraphicFormulaEditorState.display(term.atoms))
        controller.redoChange()
        field.reconcile(controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false))
        #expect(field.text=="H2O")
        field.text = "H2Ox"
        controller.updateReactionTerm(sceneID: sceneID,termID: term.id,products: false) { $0.atoms = ["C":1,"O":2] }
        let external = controller.formulaObservation(sceneID: sceneID,termID: term.id,products: false)
        field.reconcile(external);#expect(field.text=="CO2" && external.origin==nil)
        #expect(await controller.flushForExit())
    }
    @Test func substitutedMovieWithMatchingAlphaCannotVerifyOrPublishAsTheOriginalRender() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository();var red = GraphicScene.preset(.object);red.width = 320;red.height = 240;red.frameCount = 2;red.object!.color = .init(r: 1,g: 0,b: 0)
        let snapshot = try await repo.create(project,id: UUID(),label: "Red scene",scene: red),assets = try await GraphicAssetResolver().resolve(snapshot.draft.scene,project: project)
        let job = try await repo.prepareExport(project,snapshot: snapshot,id: UUID(),assets: assets)
        let original = try await GraphicAnimationExporter().export(snapshot.draft.scene,assets: assets,to: job.folder)
        let alternate = root.appendingPathComponent("alternate-blue");try FileManager.default.createDirectory(at: alternate,withIntermediateDirectories: true)
        var blue = snapshot.draft.scene;blue.object!.color = .init(r: 0,g: 0,b: 1)
        let otherFolder = try SourceRenderDirectory.open(alternate),other = try await GraphicAnimationExporter().export(blue,assets: assets,to: otherFolder)
        #expect(original.movie != other.movie)
        let blueProof = try await GraphicMovieVerifier().verify(otherFolder,scene: blue,output: other)
        try Data(contentsOf: other.movieURL).write(to: original.movieURL,options: .atomic)
        await #expect(throws: (any Error).self) { _ = try await GraphicMovieVerifier().verify(job.folder,scene: snapshot.draft.scene,output: original) }
        await #expect(throws: (any Error).self) { _ = try await repo.publishExport(project,job: job,output: original,proof: blueProof) }
        #expect(try await repo.load(project,id: snapshot.draft.id)==snapshot)
        #expect(try await repo.currentExport(project,sceneID: snapshot.draft.id)==nil)
    }

}

private actor GraphicTestProgress { var value = 0;func set(_ number: Int) { value = number } }
