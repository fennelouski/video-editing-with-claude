import AppKit

@MainActor enum FileDialogs {
    static func folder(initial: URL? = nil) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.prompt = "Choose Folder"
        if let initial, FileManager.default.fileExists(atPath: initial.path) { panel.directoryURL = initial }
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
    static func files() async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add Files"
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.urls : []) }
        }
    }
}
