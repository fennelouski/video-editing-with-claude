import Foundation
import Observation

/// Where a project's Final Cut library currently lives.
///
/// Clauto never moves media and its own project folders stay on the configured
/// NAS workspace. A separate tool, Clauto Sync
/// (~/Library/Application Support/Clauto Sync/clauto-sync), copies Final Cut
/// libraries and their clips to this Mac for fast editing and back again, then
/// writes status.json. This type only reads that file and, when asked, runs the
/// tool. Without the tool installed nothing is shown and nothing changes.
enum ProjectAvailability: String, Sendable {
    case onThisMac = "mac", onNAS = "nas", copying = "busy"

    var label: String {
        switch self {
        case .onThisMac: "On this Mac"
        case .onNAS: "On the NAS"
        case .copying: "Copying"
        }
    }
}

struct ProjectSyncSnapshot: Decodable, Sendable {
    struct Library: Decodable, Sendable {
        var name: String
        var location: String
        var clautoProjects: [String]?
    }
    var nasConnected: Bool
    var projects: [Library]
}

@MainActor @Observable final class ProjectAvailabilityMonitor {
    static let shared = ProjectAvailabilityMonitor()

    private(set) var snapshot: ProjectSyncSnapshot?
    private(set) var runningLibrary: String?
    /// The handoff's own plain explanation when it stopped and needs Katie.
    private(set) var failure: String?
    /// The handoff's plain summary when it finished.
    private(set) var message: String?
    /// The latest step while a handoff runs, e.g. "Copying 23 clips…".
    private(set) var progress: String?

    @ObservationIgnored let toolHome: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var statusModified: Date?

    init(toolHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clauto Sync", isDirectory: true)) {
        self.toolHome = toolHome
    }

    private var handoffTool: URL { toolHome.appendingPathComponent("clauto-handoff") }
    private var statusFile: URL { toolHome.appendingPathComponent("status.json") }
    var installed: Bool { FileManager.default.isExecutableFile(atPath: handoffTool.path) }

    /// Claude may move projects from a terminal session at any time, so the
    /// file is re-read whenever it changes rather than cached for the session.
    func startWatching() {
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: statusFile.path))?[.modificationDate] as? Date
        guard modified != statusModified || modified == nil else { return }
        statusModified = modified
        // An unreadable or missing file means "not known": show no symbol rather
        // than a guess that could say a project is here when it isn't.
        snapshot = (try? Data(contentsOf: statusFile)).flatMap { try? JSONDecoder().decode(ProjectSyncSnapshot.self, from: $0) }
    }

    /// The Final Cut library tied to a Clauto project folder (by folder name;
    /// links are recorded with `clauto-sync link LIBRARY FOLDER`).
    func library(forProjectFolder path: String) -> ProjectSyncSnapshot.Library? {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        return snapshot?.projects.first { ($0.clautoProjects ?? []).contains(folder) }
    }

    func availability(forProjectFolder path: String) -> ProjectAvailability? {
        guard let library = library(forProjectFolder: path) else { return nil }
        if runningLibrary == library.name { return .copying }
        return ProjectAvailability(rawValue: library.location)
    }

    /// "Start working on NAME here": brings the library to this Mac if needed and
    /// opens it in Final Cut on Katie's own timeline (or a new A-Cam timeline).
    func startWorkingHere(_ library: String) { run(["here", library]) }
    /// "Hand off to Nathan": puts the library back on the NAS, verified.
    func handOffToNathan(_ library: String) { run(["nathan", library]) }
    func clearFailure() { failure = nil }
    func clearMessage() { message = nil }

    /// Runs clauto-handoff, which tries the steps itself, asks Claude to fix
    /// anything that stops them, and falls back to retrying on its own when
    /// Claude isn't available. Its last line is "RESULT: <sentence for Katie>".
    private func run(_ arguments: [String]) {
        guard runningLibrary == nil, installed else { return }
        runningLibrary = arguments[1]; failure = nil; message = nil; progress = nil
        let tool = handoffTool
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.execute(tool, arguments) { line in
                guard line.hasPrefix("PROGRESS: ") || !line.hasPrefix("RESULT: ") else { return }
                let text = line.hasPrefix("PROGRESS: ") ? String(line.dropFirst("PROGRESS: ".count)) : line
                Task { @MainActor in self?.progress = text }
            }
            await self?.finish(result)
        }
    }

    func finish(_ result: (status: Int32, output: String)) {
        runningLibrary = nil; progress = nil
        let lines = result.output.split(separator: "\n").map(String.init)
        let summary = lines.last { $0.hasPrefix("RESULT: ") }.map { String($0.dropFirst("RESULT: ".count)) }
            ?? lines.last { $0.hasPrefix("STOPPED: ") }.map { String($0.dropFirst("STOPPED: ".count)) }
        if result.status == 0 { message = summary ?? "Done." }
        else { failure = summary ?? "The handoff stopped without saying why. Ask Claude to check its log." }
        statusModified = nil; reload()
    }

    nonisolated private static func execute(_ tool: URL, _ arguments: [String],
                                            onLine: @escaping @Sendable (String) -> Void) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = tool; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (1, "RESULT: \(error.localizedDescription)") }
        var all = Data(), pending = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            all.append(chunk); pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: all, as: UTF8.self))
    }
}
