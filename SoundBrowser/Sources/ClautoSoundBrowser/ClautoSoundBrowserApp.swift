import SwiftUI
import AppKit
import SoundBrowserCore
import SoundBrowserUI

@MainActor final class SilentQAPlayer: SoundPlaying {
    private(set) var starts = 0
    func start(data: Data, volume: Float, finished: @escaping @MainActor () -> Void) throws {
        starts += 1
        throw SoundFailure.invalid("Audio output is disabled in automated QA.")
    }
    func stop() {}
    func setVolume(_ volume: Float) {}
}

@main struct ClautoSoundBrowserApp: App {
    @State private var store: SoundBrowserStore?
    private let startupError: String?
    private let qaOutput: URL?
    private let qaRoot: URL?
    private let qaPlayer: SilentQAPlayer?
    init() {
        let args = ProcessInfo.processInfo.arguments
        func option(_ key: String) -> URL? {
            guard let i = args.firstIndex(of: key), i+1 < args.count else { return nil }
            return URL(fileURLWithPath: args[i+1],isDirectory: true)
        }
        let output = option("--qa-output")
        qaOutput = output; qaRoot = output != nil ? option("--qa-library") : nil
        let prefs = output?.appendingPathComponent("browser-preferences.json") ?? FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("Clauto Sound Browser/browser-preferences.json")
        let silent = output != nil ? SilentQAPlayer() : nil
        qaPlayer = silent
        do {
            let catalog = try SoundCatalog.bundled()
            _store = State(initialValue: SoundBrowserStore(catalog: catalog, preferencesURL: prefs, player: silent))
            startupError = nil
        } catch {
            _store = State(initialValue:nil); startupError = error.localizedDescription
        }
    }
    var body: some Scene {
        WindowGroup("Clauto · Sound library") {
          if let store {
            SoundBrowserView(store: store)
                .task {
                    if let qaOutput { await captureQA(store:store,output: qaOutput) }
                    else if !store.mounts.isEmpty { await store.recheck() }
                }
          } else {
            ContentUnavailableView("Catalog unavailable",systemImage:"exclamationmark.triangle",description:Text(startupError ?? "Restore the pinned catalog release.")).frame(width:600,height:400)
          }
        }.defaultSize(width: 1220,height: 790)
            .commands {
                CommandGroup(after: .newItem) { Button("Stop audition") { store?.stop() }.keyboardShortcut(".",modifiers: .command) }
            }
    }
    private func captureQA(store: SoundBrowserStore, output: URL) async {
        do {
            try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
            await settle()
            try snapshot("01-disconnected",output: output)
            if let qaRoot { await store.link(qaRoot) }
            store.availableOnly = true; await settle(); store.select("BSB-1399")
            await settle(); try snapshot("02-real-envelope",output: output)
            store.select("BSB-1399"); store.select("BSB-1399")
            store.toggleFavorite("BSB-1399"); store.toggleFavorite("BSB-1399"); store.toggleFavorite("BSB-1399")
            if let id = store.createCollection("Scene accents") { store.toggleMembership(assetID:"BSB-1399",collectionID:id) }
            _ = store.prepareSelection()
            await settle(); try snapshot("03-selection-contract",output: output)
            store.query = "boing"; await settle(); store.select("BSB-2278")
            await settle(); try snapshot("04-search",output: output)
            store.query = "no-sound-matches-this-query"
            await settle(); try snapshot("05-empty",output: output)
            store.query = ""; store.availableOnly = false; store.category = "Paper and stationery"; await settle(); store.select("BSB-0785")
            NSApp.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: 860,height: 640))
            await settle(); try snapshot("06-missing-compact",output: output)
            NSApp.windows.first(where: { $0.isVisible })?.appearance = NSAppearance(named: .darkAqua)
            await settle(); try snapshot("07-dark",output: output)
            store.cancelCheck(); store.stop(); store.stop()
            let report: [String:Any] = ["catalogCount":store.catalog.assets.count,"availableCount":store.availableCount,"playerStarts":qaPlayer?.starts ?? -1,"auditionStatus":"NOT_AUDITIONED","capture":"Native running NSWindow contentView cacheDisplay; no screen recording or input synthesis","flows":["selection","repeated selection","favorite toggles","collection membership","reference preparation","text search","empty search","missing asset","resize","dark appearance","cancel check","repeated stop"]]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("runtime-report.json"))
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("qa-error.txt"))
        }
        NSApp.terminate(nil)
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
    private func snapshot(_ name: String, output: URL) throws {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw SoundFailure.invalid("Native window capture unavailable.") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw SoundFailure.invalid("Native window PNG unavailable.") }
        try data.write(to:output.appendingPathComponent(name+".png"))
    }
}
