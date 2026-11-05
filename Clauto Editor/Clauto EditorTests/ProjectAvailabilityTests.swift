import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@MainActor struct ProjectAvailabilityTests {
    private func toolHome(status: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let status { try Data(status.utf8).write(to: home.appendingPathComponent("status.json")) }
        return home
    }

    @Test func linkedProjectsReportWhereTheirLibraryIs() throws {
        let home = try toolHome(status: """
        {"updated":1,"nasConnected":true,"localLimitGB":256,"minFreeGB":150,"localUsedKB":10,"freeKB":10,"projects":[
         {"name":"Pan Seasoning","location":"mac","sizeKB":10,"lastUsed":1,"path":"/x","clautoProjects":["Pan Seasoning — Katie 2026-10-24"]},
         {"name":"Yeast Pizza","location":"nas","clautoProjects":["Pizza","Pizza Yeast v7 review-14FB82F1"]},
         {"name":"Brown Sugar","location":"busy","clautoProjects":[]}]}
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        let monitor = ProjectAvailabilityMonitor(toolHome: home)
        monitor.reload()
        #expect(monitor.availability(forProjectFolder: "/Volumes/Videos/Projects/Pan Seasoning — Katie 2026-10-24") == .onThisMac)
        #expect(monitor.availability(forProjectFolder: "/Volumes/Videos/Projects/Pizza/") == .onNAS)
        #expect(monitor.library(forProjectFolder: "/Volumes/Videos/Projects/Pizza Yeast v7 review-14FB82F1")?.name == "Yeast Pizza")
        // A project with no linked library shows no symbol rather than a guess.
        #expect(monitor.availability(forProjectFolder: "/Volumes/Videos/Projects/Sugar — Katie 2026-10-24") == nil)
    }

    @Test func newProjectsCanBeStartedAndPreviewsAreFoundOnlyIfPresent() throws {
        let home = try toolHome(status: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let movie = home.appendingPathComponent("A — A-Cam in order — 2026-11-05 2000.mp4")
        try Data("x".utf8).write(to: movie)
        try Data("""
        {"nasConnected":true,"projects":[
         {"name":"Fresh Idea","location":"new","clautoProjects":["Fresh Idea"]},
         {"name":"A","location":"nas","preview":"\(movie.path)","clautoProjects":["P"]},
         {"name":"B","location":"mac","preview":"/nonexistent/old.mp4","clautoProjects":["Q"]}]}
        """.utf8).write(to: home.appendingPathComponent("status.json"))
        let monitor = ProjectAvailabilityMonitor(toolHome: home)
        monitor.reload()
        // A project with no library yet gets the same "Start working here" as one on the NAS.
        #expect(monitor.availability(forProjectFolder: "/x/Fresh Idea") == .onNAS)
        #expect(monitor.preview(forProjectFolder: "/x/P") == movie)
        // A listed preview that's gone from disk isn't offered.
        #expect(monitor.preview(forProjectFolder: "/x/Q") == nil)
        #expect(monitor.preview(forProjectFolder: "/x/Fresh Idea") == nil)
    }

    @Test func missingOrDamagedStatusShowsNothing() throws {
        for status in [nil, "{not json", "{\"projects\":[]}"] {
            let home = try toolHome(status: status)
            defer { try? FileManager.default.removeItem(at: home) }
            let monitor = ProjectAvailabilityMonitor(toolHome: home)
            monitor.reload()
            #expect(monitor.availability(forProjectFolder: "/Volumes/Videos/Projects/Pizza") == nil)
            #expect(!monitor.installed)
        }
    }

    @Test func statusIsReReadWhenTheSyncToolRewritesIt() throws {
        let home = try toolHome(status: #"{"nasConnected":true,"projects":[{"name":"A","location":"nas","clautoProjects":["P"]}]}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let monitor = ProjectAvailabilityMonitor(toolHome: home)
        monitor.reload()
        #expect(monitor.availability(forProjectFolder: "/p/P") == .onNAS)
        let file = home.appendingPathComponent("status.json")
        try Data(#"{"nasConnected":true,"projects":[{"name":"A","location":"mac","clautoProjects":["P"]}]}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        monitor.reload()
        #expect(monitor.availability(forProjectFolder: "/p/P") == .onThisMac)
    }

    private func handoff(_ home: URL, script: String) throws {
        let tool = home.appendingPathComponent("clauto-handoff")
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    @Test func aHandoffThatNeedsKatieSurfacesItsOwnExplanation() async throws {
        let home = try toolHome(status: #"{"nasConnected":false,"projects":[{"name":"A","location":"nas","clautoProjects":["P"]}]}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        try handoff(home, script: "#!/bin/sh\necho 'PROGRESS: Starting…'\necho \"RESULT: The NAS isn't connected. Wake Nathan's Mac Studio.\"\nexit 1\n")
        let monitor = ProjectAvailabilityMonitor(toolHome: home)
        monitor.reload()
        #expect(monitor.installed)
        monitor.startWorkingHere("A")
        #expect(monitor.availability(forProjectFolder: "/p/P") == .copying)
        for _ in 0..<200 where monitor.runningLibrary != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(monitor.runningLibrary == nil && monitor.progress == nil && monitor.message == nil)
        #expect(monitor.failure == "The NAS isn't connected. Wake Nathan's Mac Studio.")
        #expect(monitor.availability(forProjectFolder: "/p/P") == .onNAS)
    }

    @Test func aFinishedHandoffReportsItsSummaryAndPassesTheButtonsAction() async throws {
        let home = try toolHome(status: #"{"nasConnected":true,"projects":[{"name":"A","location":"mac","clautoProjects":["P"]}]}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let args = home.appendingPathComponent("args.txt")
        try handoff(home, script: "#!/bin/sh\necho \"$1|$2\" > '\(args.path)'\necho 'PROGRESS: Copying…'\nsleep 0.3\necho 'RESULT: A is back on the NAS. Nathan can open it now.'\n")
        let monitor = ProjectAvailabilityMonitor(toolHome: home)
        monitor.reload()
        monitor.handOffToNathan("A")
        var sawProgress = false
        for _ in 0..<200 where monitor.runningLibrary != nil {
            if monitor.progress == "Copying…" { sawProgress = true }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawProgress)
        #expect(monitor.failure == nil)
        #expect(monitor.message == "A is back on the NAS. Nathan can open it now.")
        #expect(try String(contentsOf: args, encoding: .utf8) == "nathan|A\n")
    }
}
