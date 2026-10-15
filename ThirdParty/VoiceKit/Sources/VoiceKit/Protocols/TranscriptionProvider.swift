//
//  TranscriptionProvider.swift
//  VoiceKit
//
//  Protocol abstraction for swappable speech recognition backends.
//

import Foundation

/// A provider that can transcribe speech into text via an async stream.
///
/// Conform to this protocol to implement alternative backends (e.g. Whisper, cloud APIs)
/// while keeping the same consumer code.
///
/// The default implementation shipped with VoiceKit is `SpeechRecognitionService`,
/// which uses Apple's on-device SpeechTranscriber pipeline.
public protocol TranscriptionProvider: Sendable {
    /// Start transcription and return a stream of results.
    /// - Parameter locale: Optional locale hint. Nil uses the provider's default.
    /// - Returns: An async stream of `TranscriptionResult` values.
    func startTranscription(locale: Locale?) async throws -> AsyncStream<TranscriptionResult>

    /// Stop the current transcription session and release resources.
    func stopTranscription() async
}
