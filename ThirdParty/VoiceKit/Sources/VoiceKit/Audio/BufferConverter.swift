//
//  BufferConverter.swift
//  VoiceKit
//
//  Converts AVAudioPCMBuffer between formats (e.g. mic input -> SpeechAnalyzer format).
//  Reuses the AVAudioConverter across calls for efficiency.
//

@preconcurrency import AVFoundation
import Foundation

/// Converts audio buffers between formats, caching the converter for efficiency.
public nonisolated class BufferConverter: @unchecked Sendable {
    public enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private var lastOutputFormat: AVAudioFormat?

    public init() {}

    /// Convert a buffer to the target format. Returns the original buffer if formats already match.
    /// Caches the AVAudioConverter across calls; recreates only if the input format changes.
    public func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format

        // If formats match, return as-is
        if inputFormat == format {
            return buffer
        }

        // Create or reuse converter
        if converter == nil || lastInputFormat != inputFormat || lastOutputFormat != format {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: format) else {
                throw Error.failedToCreateConverter
            }
            converter = newConverter
            lastInputFormat = inputFormat
            lastOutputFormat = format
        }

        guard let converter else {
            throw Error.failedToCreateConverter
        }

        // Calculate output frame capacity based on sample rate ratio
        let ratio = format.sampleRate / inputFormat.sampleRate
        let capacity = ceil(Double(buffer.frameLength) * ratio)
        guard capacity.isFinite, capacity > 0, capacity <= Double(UInt32.max) else {
            throw Error.failedToCreateConversionBuffer
        }
        let outputFrameCapacity = AVAudioFrameCount(capacity)
        guard outputFrameCapacity > 0 else {
            throw Error.failedToCreateConversionBuffer
        }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCapacity) else {
            throw Error.failedToCreateConversionBuffer
        }

        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard !supplied else { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || conversionError != nil {
            throw Error.conversionFailed(conversionError)
        }

        return outputBuffer
    }
}
