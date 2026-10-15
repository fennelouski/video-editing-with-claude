//
//  CaptureHeartbeat.swift
//  VoiceKit
//
//  How long since the microphone last handed us a buffer.
//
//  A dead capture is silent in exactly the same way a quiet room is, so the app
//  cannot tell them apart from the transcript alone — which is how a session ends
//  up running for a full minute having heard nothing at all. Buffers, unlike
//  speech, arrive continuously whether or not anyone is talking, so their absence
//  is unambiguous: the audio path is broken.
//

import Foundation

/// Records the time of the most recent audio buffer, written from the tap callback
/// and read from whichever actor is supervising the session.
final class CaptureHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -Double.infinity

    /// Call for every buffer the tap delivers.
    func beat() {
        lock.lock()
        last = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// Restart the clock — call when capture (re)starts, so the gap before the first
    /// buffer arrives isn't mistaken for a failure.
    func reset() {
        beat()
    }

    /// Seconds since the last buffer. Large means the microphone has stopped feeding us.
    var silence: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return max(0, ProcessInfo.processInfo.systemUptime - last)
    }
}
