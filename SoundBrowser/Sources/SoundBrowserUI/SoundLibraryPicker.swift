import AppKit
import Observation
import SoundBrowserCore

@Observable @MainActor public final class SoundLibraryPicker {
    public private(set) var isPresented = false
    private var panel: NSOpenPanel?
    public init() {}
    @discardableResult public func choose(store: SoundBrowserStore, directory: URL? = nil) async -> Bool {
        guard !isPresented else { return false }
        store.stop();isPresented = true
        let panel = NSOpenPanel();self.panel = panel
        panel.canChooseFiles = false;panel.canChooseDirectories = true;panel.allowsMultipleSelection = false
        panel.prompt = "Link folder";panel.message = "Choose one sound package root containing audio/ and asset-library.json."
        panel.directoryURL = directory
        let url: URL? = await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in continuation.resume(returning:response == .OK ? panel.url : nil) }
            // Setup is already a SwiftUI sheet. Attaching another sheet to its
            // root queues the picker behind setup and strands the Link action.
            panel.begin(completionHandler:completion)
        }
        self.panel = nil;isPresented = false
        guard let url else { return false }
        let before = store.mounts.count
        await store.link(url)
        return store.mounts.count >= before && store.error == nil
    }
    public func cancel() { panel?.cancel(nil) }
    /// The isolated QA host targets this real panel object; it never sends global
    /// input or treats the automated fixture choice as a human approval.
    public func acceptCurrentDirectoryForQA() { panel?.ok(nil) }
}
