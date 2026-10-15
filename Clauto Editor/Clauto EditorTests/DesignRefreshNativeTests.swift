#if !canImport(ClautoCore)
import AppKit
import AVKit
import AVFoundation
import SwiftUI
import Testing
@testable import Clauto_Editor

@MainActor @Suite(.serialized) struct DesignRefreshNativeTests {
    private func version() -> CutVersion { .init(number: 1,label: "Synthetic only",engineVersion: "synthetic",runID: UUID(),artifacts: [],approvedPlanHash: String(repeating: "0",count: 64)) }
    @Test func windowScopedSessionsAndReparentKeepExactlyOnePlayer() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = EditorStore(), a = ReviewWindowRouter(), b = ReviewWindowRouter(), v = version()
        a.store = store; b.store = store
        let url = f.project.folder.appendingPathComponent(f.target.preview.relativePath)
        let first = store.reviewPlayer(project: f.project,version: v,url: url,ownerID: a.id)
        let same = store.reviewPlayer(project: f.project,version: v,url: url,ownerID: a.id)
        let second = store.reviewPlayer(project: f.project,version: v,url: url,ownerID: b.id)
        defer { first.dispose(); second.dispose() }
        #expect(first === same && first !== second && first.player !== second.player)
        let presentation = first.presentation, player = first.player, item = first.player.currentItem
        let host = NSView(frame: CGRect(x: 0,y: 0,width: 640,height: 360))
        presentation.mount(host); presentation.mount(host)
        #expect(presentation.surface.superview === host && host.subviews.count == 1)
        player.isMuted = true; player.volume = 0.35
        presentation.detach(showWindow: false)
        #expect(presentation.detached && presentation.native.player === player)
        // Offscreen structure test: no foreground, no fabricated physical/PiP evidence.
        presentation.dock()
        #expect(!presentation.detached && first.player === player && first.player.currentItem === item)
        #expect(player.isMuted && player.volume == 0.35)
        #expect(presentation.native.allowsPictureInPicturePlayback)
        #expect(presentation.native.pictureInPictureDelegate === presentation)
        presentation.playerView(presentation.native,failedToStartPictureInPictureWithError: WorkflowFailure.invalid("Synthetic PiP failure"))
        #expect(first.issue == nil && first.presentationNotice != nil)
        presentation.playerViewWillStartPicture(inPicture: presentation.native)
        #expect(presentation.ownsExternalSurface)
        presentation.playerViewDidStartPicture(inPicture: presentation.native)
        first.leaveWorkspace(); #expect(presentation.ownsExternalSurface)
        presentation.playerViewDidStopPicture(inPicture: presentation.native)
        #expect(!presentation.ownsExternalSurface && player.rate == 0)
        #expect(first.endpoint == nil)
    }
    @Test func themePreferencesPreserveOtherSettingsAndUnknownIDsFallBack() throws {
        let suite = "clauto-theme-"+UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep",forKey: "Unrelated")
        let theme = ClautoThemeStore(defaults: defaults)
        #expect(theme.selected == .homey)
        for id in ClautoThemeID.allCases { theme.choose(id); #expect(ClautoThemeStore(defaults: defaults).selected == id) }
        #expect(defaults.string(forKey: "Unrelated") == "keep")
        defaults.set("obsolete",forKey: "ClautoTheme"); #expect(ClautoThemeStore(defaults: defaults).selected == .homey)
    }
    @Test func syntheticReviewLayoutRendersAtMinimumWidth() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = EditorStore(), router = ReviewWindowRouter(); router.store = store
        store.projects = [f.project]; store.selectedID = f.project.id; router.tab = "Cut"
        var v = version()
        v.artifacts = ["exports/review.mp4","exports/cut.fcpxml","plan/cut.plan.json","inputs/brief.md","inputs/script/approved.md"]
        v.approvedScript = "inputs/script/approved.md"; v.approvedPlanHash = f.target.approvedPlanSHA256; v.briefHash = f.target.approvedBriefSHA256
        let base = f.project.folder.appendingPathComponent("cuts/v001")
        let xml = Data("<fcpxml version=\"1.13\"><resources/><library><event><project><sequence duration=\"3003/2000s\"><spine/></sequence></project></event></library></fcpxml>".utf8)
        try xml.write(to: base.appendingPathComponent("exports/cut.fcpxml"))
        try JSONSerialization.data(withJSONObject: ["saved_sha256":TranscriptSourceMap.sha(xml)]).write(to: base.appendingPathComponent("exports/cut.snapshot.json"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(v).write(to: base.appendingPathComponent("clauto-version.json"))
        try encoder.encode(v.id).write(to: f.project.folder.appendingPathComponent("cuts/current.json"))
        store.cutVersions[f.project.id] = [v]; store.currentCuts[f.project.id] = v
        defer { for session in store.reviewPlayers.values { session.dispose() } }
        let host = NSHostingView(rootView: ContentView(store: store,initialProjectTab: "Cut"))
        host.frame = CGRect(x: 0,y: 0,width: 900,height: 640); host.layoutSubtreeIfNeeded()
        for _ in 0..<100 { if store.reviewPlayers.values.first?.endpoint != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 900)
        let session = try #require(store.reviewPlayers.values.first)
        #expect(session.endpoint != nil && store.notice == nil)
        let before = session.presentation.surface.frame.size
        #expect(before.width >= 280 && before.height > 100)
        session.selectForVoice()
        for _ in 0..<100 { if session.voice?.target != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        if let voice = session.voice {
            let expected = try #require(voice.target)
            await voice.addTyped(text: String(repeating: "Synthetic long feedback. ",count: 80),action: .protect,start: 0,end: 0.1,expectedTarget: expected)
            try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
            #expect(session.presentation.surface.frame.size == before)
        }
        host.frame = CGRect(x: 0,y: 0,width: 1440,height: 900); host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 1440)
        host.frame = CGRect(x: 0,y: 0,width: 900,height: 640); host.layoutSubtreeIfNeeded()
        #expect(session.presentation.native.player === session.player)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds,to: bitmap)
        let bytes = try #require(bitmap.representation(using: .png,properties: [:]))
        #expect(bytes.count > 5000)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try bytes.write(to: repo.appendingPathComponent(".artifacts/design-refresh-synthetic-minimum.png"))
    }
}
#endif
