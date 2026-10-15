import AppKit

/// SwiftUI owns review state; AppKit only defers an explicit application quit.
@MainActor final class ClautoAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: EditorStore?
    private var awaitingReviewSave = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingReviewSave { return .terminateLater }
        guard let store, store.hasPendingReviewWork else { return .terminateNow }
        awaitingReviewSave = true
        Task {
            let saved = await store.flushReviewWorkForExit()
            if saved { finish(sender, terminate: true); return }
            let alert = NSAlert()
            alert.messageText = "Review work has not saved"
            alert.informativeText = "Keep editing to retry transcript or voice-review saves. Quitting without saving discards pending changes; earlier checkpoints and reviewed cuts remain."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Quit Without Saving")
            if let window = sender.keyWindow ?? sender.mainWindow {
                alert.beginSheetModal(for: window) { [weak self] response in
                    self?.finish(sender, terminate: response == .alertSecondButtonReturn)
                }
            } else { finish(sender, terminate: alert.runModal() == .alertSecondButtonReturn) }
        }
        return .terminateLater
    }

    private func finish(_ app: NSApplication, terminate: Bool) {
        awaitingReviewSave = false
        app.reply(toApplicationShouldTerminate: terminate)
    }
}
