//
//  SafeTap.swift
//  VoiceKit
//
//  Installing a microphone tap without betting the process on it.
//
//  `installTap(onBus:bufferSize:format:block:)` does not return an error when the
//  format it is handed disagrees with the hardware — it raises, and a raise that
//  reaches Swift takes the app down. The disagreement is easy to provoke: unplug a
//  pair of headphones, change the system input, or simply leave the app running
//  long enough for AVAudioEngine's idea of the input format to go stale.
//
//  Every tap in VoiceKit goes through here so that failure is a failed recording
//  rather than a crash.
//

@preconcurrency import AVFoundation
import Foundation
import os

public extension AVAudioNode {
    /// Install a tap, reporting a format the hardware won't accept as a thrown error.
    ///
    /// If `format` is rejected, this retries once with nil — which tells AVAudioEngine to
    /// use the bus's own format instead of the one we believed it had. That second attempt
    /// is the one that succeeds when the engine's cached format has gone stale, and the
    /// buffers it delivers are self-describing, so downstream converters don't care.
    ///
    /// - Throws: the underlying `NSError` if the tap can't be installed either way.
    func installTapSafely(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) throws {
        let logger = Logger(subsystem: "VoiceKit", category: "SafeTap")

        // channelCount 0 (no input device, mic not ready yet) survives a sampleRate-only
        // check and then raises deep inside AVFoundation. Reject it up front.
        var requested = format
        if let format, format.sampleRate <= 0 || format.channelCount == 0 {
            logger.error("ignoring unusable tap format \(format, privacy: .public)")
            requested = nil
        }

        // Idempotent: removeTap is a no-op when there is none, and clears one left behind
        // by a session that was interrupted between installing and removing. Safely, because
        // a node whose hardware has gone away raises here too — and being unable to remove a
        // tap that was never there must not be what stops the next one being installed.
        removeTapSafely(onBus: bus)

        do {
            try catchingObjCException {
                self.installTap(onBus: bus, bufferSize: bufferSize, format: requested, block: block)
            }
            return
        } catch {
            guard requested != nil else { throw error }
            logger.error("tap format rejected: \(error, privacy: .public) — retrying with the bus format")
        }

        removeTapSafely(onBus: bus)
        try catchingObjCException {
            self.installTap(onBus: bus, bufferSize: bufferSize, format: nil, block: block)
        }
    }

    /// Remove a tap without risking a raise from a node whose hardware has gone away.
    func removeTapSafely(onBus bus: AVAudioNodeBus) {
        try? catchingObjCException { self.removeTap(onBus: bus) }
    }
}
