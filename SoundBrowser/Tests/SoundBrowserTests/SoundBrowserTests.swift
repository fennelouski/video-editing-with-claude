import XCTest
@testable import SoundBrowserCore

final class SoundBrowserTests: XCTestCase {
    func fixture() throws -> (SoundCatalog, URL) {
        let c = try SoundCatalog.bundled()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-sound-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return (c,root)
    }
    func representativeRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["CLAUTO_SFX_TEST_ROOT"] else { throw XCTSkip("Set CLAUTO_SFX_TEST_ROOT to the explicitly materialized eight-sound package.") }
        return URL(fileURLWithPath:path,isDirectory:true)
    }
    func testCatalogSearchUsesStableIDsTagsCategoriesAndAllWords() throws {
        let c = try SoundCatalog.bundled()
        XCTAssertEqual(c.assets.count,1162); XCTAssertEqual(c.categories.count,20)
        XCTAssertEqual(c.version,"3.0.0")
        XCTAssertEqual(c.asset("BSB-1399")?.auditionStatus,"NOT_AUDITIONED")
        XCTAssertEqual(c.search(text:"bSb-1399").map(\.id),["BSB-1399"])
        XCTAssertTrue(c.search(text:"BOING cartoon").contains { $0.id == "BSB-2278" })
        XCTAssertTrue(c.search(text:"boing impossible-word").isEmpty)
        XCTAssertTrue(c.search(category:"Crowds and applause").allSatisfy { $0.category == "Crowds and applause" })
        XCTAssertTrue(c.search(tag:"idea").contains { $0.id == "BSB-1399" })
        XCTAssertTrue(c.assets.allSatisfy { $0.license == "CC0-1.0" && $0.auditionStatus == "NOT_AUDITIONED" })
    }
    func testReferenceCannotChangeHashVersionURIOrTimebase() throws {
        let c = try SoundCatalog.bundled(), a = c.asset("BSB-1399")!
        let r = SoundSelectionReference(catalog:c,asset:a)
        XCTAssertEqual(try r.validate(catalog:c).id,a.id)
        for field in ["expectedSHA256","libraryVersion","assetURI"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(r.json().utf8)) as? [String:Any]);json[field] = "wrong"
            let bad = try JSONDecoder().decode(SoundSelectionReference.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertThrowsError(try bad.validate(catalog:c))
        }
        let request = try SoundInsertionRequest(reference:r,timelineStartFrame:120,sourceStartFrame:0,durationFrames:24,gainDB:-18)
        try request.validate(catalog:c)
        XCTAssertEqual(try JSONDecoder().decode(SoundInsertionRequest.self,from:JSONEncoder().encode(request)),request)
        XCTAssertThrowsError(try SoundInsertionRequest(reference:r,timelineStartFrame:-1,sourceStartFrame:0,durationFrames:1,gainDB:0))
        XCTAssertThrowsError(try SoundInsertionRequest(reference:r,timelineStartFrame:0,sourceStartFrame:Int64.max,durationFrames:1,gainDB:0))
        XCTAssertThrowsError(try SoundInsertionRequest(reference:r,timelineStartFrame:Int64.max,sourceStartFrame:0,durationFrames:1,gainDB:0))
        XCTAssertThrowsError(try SoundInsertionRequest(reference:r,timelineStartFrame:0,sourceStartFrame:0,durationFrames:1000,gainDB:0))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as? [String:Any]); json["frameDurationDenominator"] = 24
        XCTAssertThrowsError(try JSONDecoder().decode(SoundInsertionRequest.self,from:JSONSerialization.data(withJSONObject:json)))
        XCTAssertFalse(try r.json().contains("/Users/")); XCTAssertFalse(try r.json().contains("libfile_"))
    }
    func testRootedReadsRejectTraversalSymlinksAndNonFiles() throws {
        let (_,root) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        for path in ["/audio/a.wav","../a.wav","audio//a.wav","audio/./a.wav","file:///tmp/a.wav","C:\\a.wav","audio/a\0.wav"] {
            XCTAssertThrowsError(try LibraryFiles.components(path))
        }
        let outside = root.appendingPathComponent("outside");try Data([1,2,3]).write(to:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.wav"),withDestinationURL:outside)
        XCTAssertThrowsError(try LibraryFiles.read(root:root,path:"link.wav",limit:10))
        XCTAssertThrowsError(try LibraryFiles.read(root:root,path:"outside",limit:2))
        XCTAssertEqual(try LibraryFiles.read(root:root,path:"outside",limit:3),Data([1,2,3]))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("dir"),withIntermediateDirectories:false)
        XCTAssertThrowsError(try LibraryFiles.read(root:root,path:"dir",limit:10))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("linked-dir"),withDestinationURL:root.appendingPathComponent("dir"))
        XCTAssertThrowsError(try LibraryFiles.read(root:root,path:"linked-dir/a.wav",limit:10))
    }
    func testMalformedAndUnsupportedEnvelopeIsNotInvented() throws {
        for bytes in [Data(),Data("OggS".utf8),Data(repeating:0,count:64)] { XCTAssertThrowsError(try WaveEnvelope.decode(bytes)) }
    }
    func testRealRepresentativePackageHashesDurationsAndEnvelopes() throws {
        let c = try SoundCatalog.bundled(), root = try representativeRoot()
        let assets = c.assets.filter { $0.packageID == "clauto-sfx-crowd-cartoon-v2" }
        XCTAssertEqual(assets.count,8)
        for a in assets {
            let data = try LibraryFiles.verifiedData(asset:a,root:root)
            let wave = try WaveEnvelope.decode(data)
            XCTAssertEqual(wave.duration,a.duration,accuracy:0.000002)
            XCTAssertEqual(wave.peaks.count,128);XCTAssertTrue(wave.peaks.contains { $0 > 0 })
            XCTAssertEqual(LibraryFiles.inspect(asset:a,root:root).state,.available)
        }
    }
    @MainActor func testSelectionPersistenceRepeatedActionsCancelAndMissingNeverPlay() async throws {
        let (c,temp) = try fixture();defer { try? FileManager.default.removeItem(at:temp) }
        let player = SpyPlayer(), prefs = temp.appendingPathComponent("settings.json")
        let store = SoundBrowserStore(catalog:c,preferencesURL:prefs,player:player)
        store.select("BSB-1399");store.select("BSB-1399");store.select("BSB-1399")
        XCTAssertEqual(player.starts,0);XCTAssertEqual(store.state("BSB-1399").state,.notLinked)
        XCTAssertNil(store.prepareSelection());store.dismissError()
        store.toggleFavorite("BSB-1399");store.toggleFavorite("BSB-1399");store.toggleFavorite("BSB-1399")
        let collection = try XCTUnwrap(store.createCollection("Scene accents"))
        XCTAssertEqual(store.createCollection(" scene accents "),collection)
        store.toggleMembership(assetID:"BSB-1399",collectionID:collection)
        store.addToCollection(assetID:"BSB-1399",collectionID:collection)
        store.addToCollection(assetID:"BSB-1399",collectionID:collection)
        let restored = SoundBrowserStore(catalog:c,preferencesURL:prefs,player:player)
        XCTAssertEqual(restored.favorites,["BSB-1399"]);XCTAssertEqual(restored.collections[0].assetIDs,["BSB-1399"])
        await store.link(try representativeRoot())
        XCTAssertEqual(store.availableCount,8);XCTAssertEqual(player.starts,0)
        let ref = try store.selectionReference();XCTAssertEqual(ref.assetID,"BSB-1399")
        store.query="boing";XCTAssertFalse(store.visible.isEmpty);store.tag="absent";XCTAssertTrue(store.visible.isEmpty);store.tag=nil
        let checking = Task { await store.recheck() }; await Task.yield(); store.cancelCheck();await checking.value
        XCTAssertFalse(store.busy);XCTAssertEqual(player.starts,0)
        await store.recheck()
        store.auditionSelected();XCTAssertEqual(player.starts,1)
        store.auditionSelected();XCTAssertEqual(player.starts,2)
        XCTAssertEqual(store.playingID,"BSB-1399");store.select("BSB-0785");XCTAssertNil(store.playingID)
        store.auditionSelected();XCTAssertEqual(player.starts,2);XCTAssertNotNil(store.error)
        store.stop();store.stop()
        store.unlink(try XCTUnwrap(store.mounts.first?.id));XCTAssertEqual(store.availableCount,0)
        XCTAssertEqual(store.favorites,["BSB-1399"]);XCTAssertEqual(player.starts,2)
    }
    @MainActor func testChangedOrRemovedAssetCannotBeSelectedOrAuditioned() async throws {
        let (c,temp) = try fixture();defer { try? FileManager.default.removeItem(at:temp) }
        let root = temp.appendingPathComponent("library"), a = c.asset("BSB-1399")!, path = root.appendingPathComponent(a.relativePath)
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:representativeRoot().appendingPathComponent("asset-library.json"),to:root.appendingPathComponent("asset-library.json"))
        let data = try LibraryFiles.verifiedData(asset:a,root:representativeRoot());try data.write(to:path)
        let spy = SpyPlayer(), store = SoundBrowserStore(catalog:c,preferencesURL:temp.appendingPathComponent("prefs"),player:spy)
        await store.link(root);store.select(a.id);XCTAssertEqual(store.availableCount,1)
        var changed = data;changed[changed.count-1] ^= 1;try changed.write(to:path)
        XCTAssertEqual(LibraryFiles.inspect(asset:a,root:root).state,.hashMismatch)
        XCTAssertThrowsError(try store.selectionReference());store.auditionSelected();XCTAssertEqual(spy.starts,0)
        try data.write(to:path);await store.recheck();XCTAssertEqual(store.availableCount,1)
        try FileManager.default.removeItem(at:path)
        XCTAssertThrowsError(try store.selectionReference());XCTAssertEqual(spy.starts,0)
    }
}

@MainActor final class SpyPlayer: SoundPlaying {
    var starts = 0, stops = 0
    var volume: Float = 0
    func start(data:Data,volume:Float,finished:@escaping @MainActor () -> Void) throws { starts += 1; self.volume = volume }
    func stop() { stops += 1 }
    func setVolume(_ volume:Float) { self.volume = volume }
}
