// swift-tools-version: 6.0
import PackageDescription

// Xcode remains the app build. This package tests the exact same core source files
// without needing the graphical XCTest host, accounts, or private media.
let package = Package(
    name: "ClautoCoreVerification",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ClautoCore", targets: ["ClautoCore"])],
    targets: [
        .target(name: "ClautoCore", path: "Clauto Editor/Clauto Editor", exclude: ["Views", "ContentView.swift", "Clauto_EditorApp.swift", "Assets.xcassets", "Services/EditorStore.swift", "Services/Updater.swift"],
                sources: ["Models/Project.swift", "Services/ProcessRunner.swift", "Services/ProjectRepository.swift", "Services/SetupService.swift", "Services/WorkflowRepository.swift", "Services/PipelineService.swift", "Services/HandoffExportService.swift", "Services/ClaudeSession.swift", "Services/DerivativeService.swift"]),
        .testTarget(name: "ClautoCoreTests", dependencies: ["ClautoCore"], path: "Clauto Editor/Clauto EditorTests")
    ],
    swiftLanguageModes: [.v5]
)
