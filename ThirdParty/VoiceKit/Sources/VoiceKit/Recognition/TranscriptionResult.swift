//
//  TranscriptionResult.swift
//  VoiceKit
//
//  A single recognized transcript segment: text, finality flag, and optional confidence.
//

import Foundation

/// A recognized transcript segment emitted by a transcription provider.
public struct TranscriptionResult: Sendable {
    /// Cumulative transcript text for the current utterance.
    public let text: String
    /// True when the recognizer has committed this result.
    public let isFinal: Bool
    /// Recognition confidence (0...1), if available. Nil for providers that don't report confidence.
    public let confidence: Float?
    /// Segment start time in seconds on the session's audio timeline, if the provider reports timing.
    public let start: TimeInterval?
    /// Segment end time in seconds on the session's audio timeline, if the provider reports timing.
    public let end: TimeInterval?

    public let runs: [TranscriptionRun]?

    public init(text: String, isFinal: Bool, confidence: Float? = nil,
                start: TimeInterval? = nil, end: TimeInterval? = nil, runs: [TranscriptionRun]? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.start = start
        self.end = end
        self.runs = runs
    }
}

/// Backward-compatible typealias for code migrating from SpeechService.
@available(*, deprecated, renamed: "TranscriptionResult")
public typealias TranscriptSegment = TranscriptionResult

/// Exact attributed text coverage; one run can contain several words. Missing
/// timing stays nil so clients can refuse to infer a word timestamp.
public struct TranscriptionRun: Sendable {
    public let utf16Start: Int
    public let utf16Length: Int
    public let start: TimeInterval?
    public let end: TimeInterval?
    public init(utf16Start: Int,utf16Length: Int,start: TimeInterval?,end: TimeInterval?) {
        self.utf16Start = utf16Start; self.utf16Length = utf16Length
        self.start = start; self.end = end
    }
}
