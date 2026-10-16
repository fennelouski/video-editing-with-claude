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
                sources: ["Models/ConversationHistory.swift", "Services/ConversationHistoryStore.swift","Models/GraphicCutSelection.swift",
                "Models/ConversationLocalEdit.swift",
                "Services/ConversationLocalEditRepository.swift",
                "Services/ConversationLocalEditWorker.swift",
                "Services/ConversationLocalEditController.swift", "Services/GraphicSceneExport.swift", "Services/GraphicStudioController.swift", "Models/GraphicWorkspace.swift", "Services/GraphicStudioRepository.swift", "Services/GraphicAssetResolver.swift", "Services/GraphicSceneRenderer.swift", "Services/GraphicAnimationExporter.swift", "Models/GraphicLayers.swift", "Services/GraphicFrameCompositor.swift", "Services/GraphicFrameBuilder.swift", "Services/GraphicParticleSimulation.swift", "Services/GraphicMeshImport.swift", "Models/GraphicScene.swift", "Services/GraphicMetalRenderer.swift", "Services/FontPreviewGeometry.swift", "Services/FontImageIntake.swift", "Services/FontOutlineGeometry.swift", "Services/FontStudioController.swift", "Models/FontStudio.swift", "Services/FontCompilerService.swift", "Services/FontStudioRepository.swift", "Services/CutoutAssetStoring.swift", "Services/CutoutStudioController.swift", "Models/CutoutWorkspace.swift", "Services/CreativeAssetFiles.swift", "Services/CutoutRepository.swift", "Models/CutoutAsset.swift", "Services/CutoutMaskProcessor.swift", "Services/CutoutImageIO.swift", "Services/CutoutSubjectDetector.swift", "Models/LiveConversation.swift", "Services/ClaudeAccountService.swift", "Services/ClaudeCLITransport.swift", "Services/LiveConversationRepository.swift", "Services/LiveConversationController.swift", "Models/RegionDictation.swift", "Services/RegionDictationRepository.swift", "Services/RegionDictationController.swift", "Models/VoiceSpeechIdeas.swift", "Models/VoiceFeedbackCards.swift", "Models/EditorCommand.swift", "Models/ClautoTheme.swift", "Models/FrameReview.swift", "Services/ReviewPlaybackController.swift", "Services/FrameCommentRepository.swift", "Services/FrameCommentController.swift", "Services/ReviewMovieImportService.swift", "Models/VoiceCandidateEdits.swift", "Services/VoiceCandidatePreviewService.swift", "Models/VoiceReview.swift", "Services/VoiceReviewController.swift", "Services/VoiceReviewProvenance.swift", "Services/DictateReviewAdapter.swift", "Services/VoiceReviewRepository.swift", "Models/Project.swift", "Models/TranscriptReview.swift", "Models/TranscriptSourceMap.swift", "Models/SourceSpanRender.swift", "Services/SourceRenderDirectory.swift", "Services/SyntheticSourceSpanFixture.swift", "Services/SourceSpanRenderService.swift", "Services/SourceMediaVerifier.swift", "Services/TranscriptReviewRepository.swift", "Services/TranscriptReviewController.swift", "Services/ProcessRunner.swift", "Services/ProjectRepository.swift", "Services/SetupService.swift", "Services/WorkflowRepository.swift", "Services/PipelineService.swift", "Services/HandoffExportService.swift", "Services/ClaudeSession.swift", "Services/DerivativeService.swift"], resources: [.copy("Resources/ClautoWorkSans.ttf"), .copy("Resources/WorkSans-OFL.txt")]),
        .testTarget(name: "ClautoCoreTests", dependencies: ["ClautoCore"], path: "Clauto Editor/Clauto EditorTests")
    ],
    swiftLanguageModes: [.v5]
)
