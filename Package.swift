// swift-tools-version: 6.0
import PackageDescription

// Xcode remains the app build. This package tests the exact same core source files
// without needing the graphical XCTest host, accounts, or private media.
let package = Package(
    name: "ClautoCoreVerification",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ClautoCore", targets: ["ClautoCore"])],
    dependencies: [.package(path: "ThirdParty/VoiceKit")],
    targets: [
        .target(name: "ClautoCore", dependencies: [.product(name: "VoiceKit", package: "voicekit")], path: "Clauto Editor/Clauto Editor", exclude: ["Views", "ContentView.swift", "Clauto_EditorApp.swift", "Assets.xcassets", "Services/EditorStore.swift", "Services/Updater.swift"],
                sources: ["Models/LiveConversation.swift", "Services/ClaudeAccountService.swift", "Services/ClaudeCLITransport.swift", "Services/LiveConversationRepository.swift", "Services/LiveConversationController.swift", "Models/RegionDictation.swift", "Services/RegionDictationRepository.swift", "Services/RegionDictationController.swift", "Models/VoiceSpeechIdeas.swift", "Models/VoiceFeedbackCards.swift", "Models/EditorCommand.swift", "Models/ClautoTheme.swift", "Models/FrameReview.swift", "Services/ReviewPlaybackController.swift", "Services/FrameCommentRepository.swift", "Services/FrameCommentController.swift", "Services/ReviewMovieImportService.swift", "Models/VoiceCandidateEdits.swift", "Services/VoiceCandidatePreviewService.swift", "Models/VoiceReview.swift", "Services/VoiceReviewController.swift", "Services/VoiceReviewProvenance.swift", "Services/DictateReviewAdapter.swift", "Services/VoiceReviewRepository.swift", "Models/Project.swift", "Models/TranscriptReview.swift", "Models/TranscriptSourceMap.swift", "Models/SourceSpanRender.swift", "Services/SourceRenderDirectory.swift", "Services/SyntheticSourceSpanFixture.swift", "Services/SourceSpanRenderService.swift", "Services/SourceMediaVerifier.swift", "Services/TranscriptReviewRepository.swift", "Services/TranscriptReviewController.swift", "Services/ProcessRunner.swift", "Services/ProjectRepository.swift", "Services/SetupService.swift", "Services/WorkflowRepository.swift", "Services/PipelineService.swift", "Services/HandoffExportService.swift", "Services/ClaudeSession.swift", "Services/DerivativeService.swift"]),
        .testTarget(name: "ClautoCoreTests", dependencies: ["ClautoCore"], path: "Clauto Editor/Clauto EditorTests")
    ],
    swiftLanguageModes: [.v5]
)
