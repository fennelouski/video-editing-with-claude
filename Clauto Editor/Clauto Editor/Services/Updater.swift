import Sparkle
import Observation

@MainActor @Observable
final class Updater {
    private let controller: SPUStandardUpdaterController
    let enabled: Bool

    init() {
        #if DEBUG
        enabled = false
        #else
        enabled = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: nil)
    }
    func check() { if enabled { controller.checkForUpdates(nil) } }
}
