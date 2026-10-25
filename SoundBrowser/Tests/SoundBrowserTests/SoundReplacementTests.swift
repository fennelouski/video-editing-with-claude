import XCTest
@testable import SoundBrowserCore

final class SoundReplacementTests: XCTestCase {
    func fixture() -> Data {
        Data("""
        <?xml version="1.0"?><!DOCTYPE fcpxml>
        <fcpxml version="1.13"><resources><format id="r1" frameDuration="1001/24000s" width="1920" height="1080"/><asset id="r2" name="Original"><media-rep kind="original-media" src="file:///fixture/original.wav"/></asset></resources><library><event><project><sequence format="r1" duration="48048/24000s"><spine>
        <asset-clip name="Video" ref="r2" offset="0s" start="0s" duration="48048/24000s"><asset-clip name="Original effect" ref="r2" lane="-1" offset="10010/24000s" start="20020/24000s" duration="24024/24000s" audioRole="effects.foley" srcEnable="audio"><adjust-volume amount="-15dB"><param name="amount"><keyframeAnimation><keyframe time="20020/24000s" value="-96"/><keyframe time="22022/24000s" value="-15"/><keyframe time="42042/24000s" value="-15"/><keyframe time="44044/24000s" value="-96"/></keyframeAnimation></param></adjust-volume></asset-clip></asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
    func testReplacementPreservesTimingTrimGainFadesAndUndoRedo() throws {
        let catalog=try SoundCatalog.bundled(),doc=try SoundTimelineDocument(data:fixture())
        let before=try XCTUnwrap(doc.cues.first),original=doc.data
        XCTAssertEqual([before.timelineStartFrame,before.sourceStartFrame,before.durationFrames],[10,20,24])
        // Browsing/recommendations must never alter the timeline.
        _ = doc.similarCandidates(cueID:before.id,catalog:catalog)
        XCTAssertEqual(doc.data,original)
        let longer=SoundSelectionReference(catalog:catalog,asset:try XCTUnwrap(catalog.asset("BSB-1399")))
        try doc.replace(cueID:before.id,reference:longer,sourceURL:URL(fileURLWithPath:"/fixture/idea.wav"),catalog:catalog)
        let after=try XCTUnwrap(doc.cues.first)
        XCTAssertEqual([after.timelineStartFrame,after.sourceStartFrame,after.durationFrames],[10,20,24])
        XCTAssertEqual(after.gainAndFadeXML,before.gainAndFadeXML)
        XCTAssertEqual(after.name,"Idea #2");XCTAssertTrue(doc.canUndo)
        let changed=doc.data
        try doc.replace(cueID:before.id,reference:longer,sourceURL:URL(fileURLWithPath:"/fixture/idea.wav"),catalog:catalog)
        XCTAssertEqual(doc.data,changed)
        doc.undo();XCTAssertEqual(doc.data,original);XCTAssertTrue(doc.references.isEmpty)
        doc.redo();XCTAssertEqual(doc.data,changed);XCTAssertEqual(doc.references[before.id],longer)
        let mapped=try doc.rewrittenMediaURLs([before.id:URL(fileURLWithPath:"/fixture/immutable.wav")])
        XCTAssertEqual(try SoundTimelineDocument(data:mapped).cues.first?.sourceURL?.path,"/fixture/immutable.wav")
    }
    func testShorterReplacementIsRefusedWithoutRetimingOrMutation() throws {
        let catalog=try SoundCatalog.bundled(),doc=try SoundTimelineDocument(data:fixture()),original=doc.data
        let short=SoundSelectionReference(catalog:catalog,asset:try XCTUnwrap(catalog.asset("BSB-2284")))
        XCTAssertThrowsError(try doc.replace(cueID:doc.cues[0].id,reference:short,sourceURL:URL(fileURLWithPath:"/fixture/short.wav"),catalog:catalog))
        XCTAssertEqual(doc.data,original);XCTAssertFalse(doc.canUndo)
    }
    func testExternalEntitiesAndWrongTimeGridAreRefused() throws {
        XCTAssertThrowsError(try SoundTimelineDocument(data:Data("<!DOCTYPE fcpxml SYSTEM 'https://invalid.example/test'><fcpxml/>".utf8)))
        let malformed=String(decoding:fixture(),as:UTF8.self).replacingOccurrences(of:"20020/24000s",with:"1/24000s")
        XCTAssertThrowsError(try SoundTimelineDocument(data:Data(malformed.utf8)))
    }
}
