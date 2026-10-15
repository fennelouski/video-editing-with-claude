//
//  FileTranscriber.swift
//  VoiceKit
//
//  Offline transcription of a recorded audio file, used by conversation
//  recording: capture first, transcribe after the fact — one analyzer at a
//  time instead of N live ones. Runs on-device; nothing leaves the machine.
//

@preconcurrency import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public enum FileTranscriber {
    /// Transcribe an audio file and return the finalized segments, with timestamps
    /// relative to the start of the file.
    /// - Throws: `RecognitionError.notAuthorized`, `.localeNotSupported`,
    ///   `.modelDownloadFailed`, or file-reading errors.
    public static func transcribe(fileAt url: URL, locale: Locale? = nil, allowAuthorizationRequest: Bool = true, allowModelInstallation: Bool = true) async throws -> [TranscriptionResult] {
        try Task.checkCancellation()
        let status = SpeechRecognitionService.authorizationStatus()
        if status != .authorized {
            guard allowAuthorizationRequest, status == .notDetermined,
                  await SpeechRecognitionService.requestAuthorization() == .authorized else {
                throw RecognitionError.notAuthorized
            }
        }

        try Task.checkCancellation()
        let recognitionLocale = locale ?? Locale.current
        let supportedLocales = await SpeechTranscriber.supportedLocales
        try Task.checkCancellation()
        guard supportedLocales.contains(where: {
            $0.language.languageCode == recognitionLocale.language.languageCode
        }) else {
            throw RecognitionError.localeNotSupported
        }

        let transcriber = SpeechTranscriber(locale: recognitionLocale, preset: .progressiveTranscription)
        if !allowModelInstallation {
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw RecognitionError.recognitionUnavailable }
        } else if let downloadRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            do {
                try await downloadRequest.downloadAndInstall()
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw RecognitionError.modelDownloadFailed(error)
            }
        }

        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect concurrently: results stream while the file is analyzed, and the
        // stream ends when the analyzer finishes.
        let collector = Task {
            var segments: [TranscriptionResult] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptionResult(
                    text: text, isFinal: true,
                    start: result.range.start.seconds.isFinite ? result.range.start.seconds : nil,
                    end: result.range.end.seconds.isFinite ? result.range.end.seconds : nil))
            }
            return segments
        }

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let file = try AVAudioFile(forReading: url)
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                let segments = try await collector.value
                try Task.checkCancellation()
                return segments
            } catch {
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                _ = try? await collector.value
                throw error
            }
        } onCancel: {
            collector.cancel()
            // Interrupt analyzeSequence rather than merely ignoring its eventual
            // result. The collector is unstructured and must be cancelled too.
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
