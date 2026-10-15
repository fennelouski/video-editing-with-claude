//
//  RMSCalculator.swift
//  VoiceKit
//
//  Shared RMS level calculation for audio buffers.
//  Used by both SpeechRecognitionService and MicLevelService.
//

@preconcurrency import AVFoundation
import Foundation

/// Shared utility for computing normalized RMS levels from audio buffers.
public enum RMSCalculator {
    /// Compute normalized RMS level (0...1) from an audio buffer.
    /// - Parameters:
    ///   - buffer: The audio buffer to analyze.
    ///   - scalingFactor: Multiplier for the raw RMS value before clamping to 0...1.
    ///     Use 10 for speech recognition level meters, 4 for standalone mic level capture.
    /// - Returns: Normalized level (0...1), or nil if the buffer has no usable data.
    public static func rmsLevel(from buffer: AVAudioPCMBuffer, scalingFactor: Float = 10) -> Float? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        if let channelData = buffer.floatChannelData {
            var sum: Float = 0
            for i in 0..<frames {
                let s = channelData[0][i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(frames))
            return min(1.0, rms * scalingFactor)
        }
        if let channelData = buffer.int16ChannelData {
            var sum: Float = 0
            for i in 0..<frames {
                let s = Float(channelData[0][i]) / 32768
                sum += s * s
            }
            let rms = sqrt(sum / Float(frames))
            return min(1.0, rms * scalingFactor)
        }
        return nil
    }
}
