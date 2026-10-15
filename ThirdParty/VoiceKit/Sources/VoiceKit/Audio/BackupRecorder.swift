//
//  BackupRecorder.swift
//  VoiceKit
//
//  A copy of the microphone, on disk, for the length of one dictation.
//
//  Live recognition has more ways to come back empty than it has ways to fail
//  loudly: the analyzer can wedge, the model can stall, the device can vanish
//  mid-sentence. In every one of those cases the audio itself was fine — it was
//  only the transcription that was lost. Keeping the audio means the words can be
//  recovered afterwards instead of asking the user to say it all again.
//
//  The file is a means, not a record: it is deleted the moment the dictation
//  produces text, and one kept because it couldn't be transcribed lives only
//  until the next dictation finishes. There is never more than one on disk.
//

@preconcurrency import AVFoundation
import Foundation
import os

/// Writes the session's microphone audio to a file so a failed transcription can be
/// retried offline. Downmixed to 16 kHz mono 16-bit — everything speech recognition
/// uses and nothing it doesn't.
public final class BackupRecorder: @unchecked Sendable {
    private static let logger = Logger(subsystem: "VoiceKit", category: "BackupRecorder")

    /// Enough audio to be worth transcribing. Below this it's a stray keypress.
    private static let minimumUsefulFrames: AVAudioFramePosition = 16_000 / 2

    /// Recordings currently open for writing. `sweep` spares these whatever the caller passed,
    /// because the caller can't always know about them yet: the file is opened the moment a
    /// session starts, but the owner doesn't learn its URL until `startRecognition` returns —
    /// and the awaits in between are long enough (analyzer start, first-run model download) for
    /// the previous dictation's cleanup to sweep. Deleting an open file doesn't stop the writes,
    /// it just sends them to an unlinked inode, so the loss is silent right up until recovery
    /// finds nothing.
    private static let openLock = NSLock()
    private static var openFiles: Set<URL> = []

    let url: URL

    private let lock = NSLock()
    private let converter = BufferConverter()
    /// The format buffers must be in to be written — `AVAudioFile.processingFormat`, which is
    /// *not* the format the file is encoded in. `settings` chooses the encoding on disk;
    /// `processingFormat` is what the client side speaks, and AVAudioFile traps rather than
    /// throws if handed anything else, so it has to come from the file itself.
    private let writeFormat: AVAudioFormat
    private let maxFrames: AVAudioFramePosition
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var loggedConversionFailure = false

    /// - Parameters:
    ///   - directory: created if needed; one file per session lands here.
    ///   - maxDuration: hard ceiling, so a dictation left locked on overnight can't
    ///     fill the disk. An hour at this format is 115 MB, and it's deleted when the next
    ///     dictation finishes — the ceiling only has to sit past any real dictation, because
    ///     hitting it truncates in silence and recovery then hands back half a transcript
    ///     as though it were whole.
    init?(directory: URL, maxDuration: TimeInterval = 3600) {
        // 16 kHz mono 16-bit on disk: everything speech recognition uses, nothing it doesn't.
        guard let onDisk = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ) else { return nil }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // Two dictations can start inside the same second, and opening for writing truncates:
        // a name collision would destroy the earlier recording rather than sit beside it.
        let name = "Dictation \(stamp.string(from: Date()))"
        var url = directory.appendingPathComponent("\(name).caf")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name) \(attempt).caf")
            attempt += 1
        }

        guard let opened = Self.open(url, in: directory, settings: onDisk.settings) else { return nil }

        self.url = url
        self.file = opened
        self.writeFormat = opened.processingFormat
        self.maxFrames = AVAudioFramePosition(maxDuration * onDisk.sampleRate)

        Self.openLock.lock()
        Self.openFiles.insert(url.standardizedFileURL)
        Self.openLock.unlock()
    }

    private static func open(_ url: URL, in directory: URL, settings: [String: Any]) -> AVAudioFile? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            logger.error("couldn't open backup file: \(error, privacy: .public)")
            return nil
        }
    }

    /// Append one tap buffer. Cheap enough for the tap callback, and silently gives up
    /// rather than ever disturbing the live session it exists to back up.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, framesWritten < maxFrames else { return }
        let converted: AVAudioPCMBuffer
        do {
            converted = try converter.convertBuffer(buffer, to: writeFormat)
        } catch {
            // Dropping every buffer looks exactly like a dictation too short to transcribe,
            // which is the one failure this file exists to rule out. Say so once — logging
            // per buffer would be hundreds of lines a minute from the tap callback.
            if !loggedConversionFailure {
                loggedConversionFailure = true
                Self.logger.error("backup conversion failed, recording will be empty: \(error, privacy: .public)")
            }
            return
        }

        // The converter above is what keeps this safe: a format AVAudioFile doesn't expect
        // is a trap, not an exception, and nothing can catch it. The guard below only covers
        // the conditions it does raise for, such as a file that has already been closed.
        var failure: Error?
        do {
            try catchingObjCException {
                do { try file.write(from: converted) } catch { failure = error }
            }
        } catch {
            failure = error
        }
        if let failure {
            Self.logger.error("backup write failed, giving up on this file: \(failure, privacy: .public)")
            self.file = nil
            return
        }
        framesWritten += AVAudioFramePosition(converted.frameLength)
    }

    /// Close the file. Returns its URL only if it holds enough audio to be worth
    /// transcribing; otherwise the file is removed and nil comes back.
    func finish() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        file = nil // AVAudioFile flushes and closes on deinit
        Self.openLock.lock()
        Self.openFiles.remove(url.standardizedFileURL)
        Self.openLock.unlock()
        guard framesWritten >= Self.minimumUsefulFrames else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        // Stamp the file as of *now*, so retention is counted from when the recording ended
        // rather than when it began. Writing to the file already moves the modification date
        // along, which makes this mostly a formality — but "mostly" is not what a retention
        // policy should rest on, and an hour-long dictation must not arrive already expired.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Delete recordings that have nothing left to protect. Run when a dictation finishes.
    ///
    /// By default that gives each recording a lifetime of exactly one dictation: it exists
    /// in case this one couldn't be transcribed, and the moment the next one lands its job
    /// is done. Nothing accumulates, and a file orphaned by a crash is swept up by the next
    /// dictation rather than lingering.
    ///
    /// - Parameters:
    ///   - keep: never deleted. Recordings still open for writing are spared whether or not
    ///     they appear here — see `openFiles`.
    ///   - retention: how long everything else survives *after its recording ended* — see
    ///     `finish()`, which stamps that moment. Nil — the default behaviour — means it
    ///     doesn't survive at all: this sweep is the end of it. A duration keeps recordings
    ///     until they age out instead, for tracking down a microphone that fails now and then.
    public static func sweep(_ directory: URL, keeping keep: [URL], retention: TimeInterval? = nil) {
        openLock.lock()
        let survivors = Set(keep.map(\.standardizedFileURL)).union(openFiles)
        openLock.unlock()
        let cutoff = retention.map { Date().addingTimeInterval(-$0) }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where !survivors.contains(file.standardizedFileURL) {
            if let cutoff {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                // No modification date means we can't tell how old it is. Deleting is the
                // safe direction here — this folder holds nothing anyone chose to keep.
                if let modified, modified > cutoff { continue }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
