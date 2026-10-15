//
//  SpeechRecognitionService.swift
//  VoiceKit
//
//  On-device speech recognition using Apple's SpeechAnalyzer/SpeechTranscriber.
//  Requests permission when starting; emits transcript segments for position mapping.
//  No audio or transcript sent off-device.
//

@preconcurrency import AVFoundation
import Foundation
import os
import Speech
#if os(macOS)
import CoreAudio
import AudioUnit
#endif

/// On-device speech recognition service using Apple's SpeechTranscriber pipeline.
///
/// Emits recognized transcript segments (words/phrases) for the position mapper to consume.
/// Permission is requested when starting; denied permission yields an error and manual scroll only.
///
/// - Note: Requires macOS 26+ / iOS 26+. Available on older deployment targets but
///   guarded with `@available`.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public actor SpeechRecognitionService: TranscriptionProvider {
    private static let logger = Logger(subsystem: "VoiceKit", category: "SpeechRecognitionService")

    // MARK: - SpeechAnalyzer pipeline state

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var bufferConverter: BufferConverter?

    // Audio engine. Built per session, and rebuildable within one — see `buildEngine`.
    private var audioEngine: AVAudioEngine?
    /// True from a successful start until `stopRecognition`. Distinct from `audioEngine != nil`,
    /// which goes false while the microphone is down mid-session — exactly when the supervisor
    /// most needs to be told something is wrong.
    private var sessionActive = false
    private var requestedDeviceID: UInt32?
    private let heartbeat = CaptureHeartbeat()
    private var backup: BackupRecorder?

    // Level stream for mic indicator
    private var levelContinuation: AsyncStream<Float>.Continuation?

    // Audio buffer forwarding (for camera recording mux)
    private var audioBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var timestampedAudioContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?

    // Tasks for consuming results
    private var resultsTask: Task<Void, Swift.Error>?
    private var transcriptContinuation: AsyncStream<TranscriptionResult>.Continuation?

    private let allowAuthorizationRequest: Bool
    private let allowModelInstallation: Bool
    private let allowDeviceFallback: Bool
    private var captureStampContinuation: AsyncStream<AnalyzerCaptureStamp>.Continuation?

    public init(allowAuthorizationRequest: Bool = true, allowModelInstallation: Bool = true, allowDeviceFallback: Bool = true) {
        self.allowAuthorizationRequest = allowAuthorizationRequest
        self.allowModelInstallation = allowModelInstallation
        self.allowDeviceFallback = allowDeviceFallback
    }

    /// Check current speech recognition authorization status.
    public static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Request microphone and speech recognition permission. Call before starting recognition.
    /// Returns authorization result; does not request at app launch.
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - TranscriptionProvider conformance

    /// Start transcription and return an async stream of results.
    /// This is the protocol-conforming entry point; use `startRecognition(locale:inputDeviceID:)`
    /// for access to the full `RecognitionSession` with level and audio buffer streams.
    public func startTranscription(locale: Locale?) async throws -> AsyncStream<TranscriptionResult> {
        let session = try await startRecognition(locale: locale)
        return session.transcript
    }

    /// Stop the current transcription session.
    public func stopTranscription() async {
        _ = await stopRecognition()
    }

    // MARK: - Full recognition API

    /// Start recognition and emit transcript segments and mic levels via the returned session.
    /// Call `stopRecognition()` when done.
    /// - Parameters:
    ///   - locale: Optional locale for recognition (e.g. from Settings). Nil uses system default.
    ///   - inputDeviceID: On macOS only, optional Core Audio device ID to use as input. Nil uses system default.
    ///   - backupDirectory: If set, the session's microphone audio is also written to a file
    ///     here, so a transcription that comes back empty can be retried offline. The caller
    ///     owns the file once `stopRecognition()` hands back its URL.
    /// - Throws: `RecognitionError.notAuthorized` if permission denied, `RecognitionError.localeNotSupported` if locale unavailable.
    public func startRecognition(
        locale: Locale? = nil,
        inputDeviceID: UInt32? = nil,
        backupDirectory: URL? = nil
    ) async throws -> RecognitionSession {
        do {
            try Task.checkCancellation()
            // Check authorization
            let status = Self.authorizationStatus()
            if status != .authorized {
                if status == .notDetermined && allowAuthorizationRequest {
                    let newStatus = await Self.requestAuthorization()
                    try Task.checkCancellation()
                    if newStatus != .authorized {
                        throw RecognitionError.notAuthorized
                    }
                } else {
                    throw RecognitionError.notAuthorized
                }
            }

            // Speech authorization and microphone permission are separate grants. Without this
            // check a denied mic sails past the gate above and fails deep in the audio engine as
            // an opaque OSStatus; catch it here so the caller can say "grant the mic" plainly.
            // iOS-only: a keyboard extension can't prompt, so the container app grants it first.
            #if os(iOS) || os(visionOS)
            if AVAudioApplication.shared.recordPermission != .granted {
                throw RecognitionError.notAuthorized
            }
            #endif

            // Determine locale
            let recognitionLocale = locale ?? Locale.current

            // Verify locale is supported
            let supportedLocales = await SpeechTranscriber.supportedLocales
            try Task.checkCancellation()
            let localeSupported = supportedLocales.contains { supported in
                supported.language.languageCode == recognitionLocale.language.languageCode
            }
            guard localeSupported else {
                throw RecognitionError.localeNotSupported
            }

            // Create transcriber — progressiveTranscription preset for low-latency live transcription
            let newTranscriber = SpeechTranscriber(
                locale: recognitionLocale,
                preset: .timeIndexedProgressiveTranscription
            )
            transcriber = newTranscriber

            // Ensure speech model is installed
            if !allowModelInstallation {
                guard await AssetInventory.status(forModules: [newTranscriber]) == .installed else { throw RecognitionError.recognitionUnavailable }
            } else if let downloadRequest = try await AssetInventory.assetInstallationRequest(supporting: [newTranscriber]) {
                try Task.checkCancellation()
                do {
                    try await downloadRequest.downloadAndInstall()
                    try Task.checkCancellation()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw RecognitionError.modelDownloadFailed(error)
                }
            }

            try Task.checkCancellation()
            // Create analyzer
            let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])
            analyzer = newAnalyzer

            // Get optimal audio format for the transcriber
            let optimalFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [newTranscriber])
            try Task.checkCancellation()
            analyzerFormat = optimalFormat
            bufferConverter = BufferConverter()

            // Configure audio session for recording (iOS/visionOS only; macOS handles this via AVAudioEngine).
            // `.record`, not `.playAndRecord`: dictation never plays audio, and a keyboard extension's
            // sandbox will refuse to activate a playback-capable session — that refusal is what surfaced
            // as "Couldn't start dictation". The minimal category is also the one that's granted.
            #if os(iOS) || os(visionOS)
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                try audioSession.setActive(true)
            } catch {
                throw RecognitionError.engineStartFailed(error)
            }
            #endif

            // Create the input stream for feeding audio to the analyzer
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(128))
            inputContinuation = inputBuilder

            // Start the analyzer with the input sequence
            try await newAnalyzer.start(inputSequence: inputSequence)

            try Task.checkCancellation()
            // Set up level stream
            let levelStream = AsyncStream<Float> { continuation in
                self.levelContinuation = continuation
            }

            // Set up audio buffer stream (for camera recording mux)
            // Consumers capture live audio; an absent/slow consumer must not retain the whole session.
            let audioBufferStream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .bufferingNewest(32)) { continuation in
                self.audioBufferContinuation = continuation
            }
            // Bound the unused stream while the user is prompting without recording.
            let timestampedAudioStream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(32)) { continuation in
                self.timestampedAudioContinuation = continuation
            }
            let (stampStream, stampContinuation) = AsyncStream<AnalyzerCaptureStamp>.makeStream(bufferingPolicy: .bufferingNewest(64))
            captureStampContinuation = stampContinuation

            // Set up transcript stream
            let transcriptStream = AsyncStream<TranscriptionResult> { continuation in
                self.transcriptContinuation = continuation
            }

            // Spawn task to consume transcriber results
            let capturedTranscriptCont = transcriptContinuation
            resultsTask = Task {
                do {
                    for try await result in newTranscriber.results {
                        let text = String(result.text.characters)
                        let isFinal = result.isFinal
                        guard !text.isEmpty else { continue }
                        Self.logger.debug("segment: \"\(text, privacy: .private)\" isFinal: \(isFinal)")
                        let range = result.range
                        capturedTranscriptCont?.yield(TranscriptionResult(
                            text: text, isFinal: isFinal,
                            start: range.start.seconds.isFinite ? range.start.seconds : nil,
                            end: range.end.seconds.isFinite ? range.end.seconds : nil))
                    }
                } catch {
                    Self.logger.error("results stream error: \(error)")
                }
                capturedTranscriptCont?.finish()
            }

            // Keep a copy of the audio on disk when the caller asked for one, so a session that
            // transcribes to nothing can still be salvaged.
            if let backupDirectory {
                backup = BackupRecorder(directory: backupDirectory)
            }

            try Task.checkCancellation()
            // Start capturing. Everything above this point is the analyzer, which outlives any
            // single microphone — see `restartCapture`.
            requestedDeviceID = inputDeviceID
            do {
                try startCapture(deviceID: inputDeviceID)
                sessionActive = true
            } catch {
                _ = backup?.finish()
                backup = nil
                #if os(iOS) || os(visionOS)
                try? AVAudioSession.sharedInstance().setActive(false)
                #endif
                throw error
            }

            return RecognitionSession(
                transcript: transcriptStream, level: levelStream,
                audioBuffers: audioBufferStream, backupURL: backup?.url,
                timestampedAudioBuffers: timestampedAudioStream, captureStamps: stampStream
            )
        } catch {
            // Failed or cancelled starts may already own an analyzer and streams.
            let backupURL = await cancelRecognition()
            if Task.isCancelled, let backupURL { try? FileManager.default.removeItem(at: backupURL) }
            throw error
        }
    }

    // MARK: - Capture

    /// Seconds since the microphone last delivered a buffer. Buffers keep arriving through
    /// silence, so a large value means the audio path is broken, not that nobody is talking.
    /// Zero when there is no session, so an idle app never looks stalled.
    public func silenceDuration() -> TimeInterval {
        sessionActive ? heartbeat.silence : 0
    }

    /// Tear the microphone down and bring it back up, leaving the analyzer and everything
    /// already transcribed untouched. This is the recovery for a device that disappeared
    /// mid-sentence: the user keeps talking and only loses the moment it took to reconnect.
    /// - Returns: false if there is no session to restart, or if the microphone didn't come back.
    @discardableResult
    public func restartCapture() -> Bool {
        guard sessionActive else { return false }
        teardownEngine()
        do {
            try startCapture(deviceID: requestedDeviceID)
            Self.logger.notice("capture restarted")
            return true
        } catch {
            Self.logger.error("capture restart failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Build and start the microphone, falling back to the system default input if the
    /// requested device won't open.
    private func startCapture(deviceID: UInt32?) throws {
        do {
            try buildEngine(deviceID: deviceID)
        } catch {
            // A stored device ID is the usual suspect. Core Audio renumbers devices as
            // hardware comes and goes, so yesterday's ID can name something else entirely
            // today — or nothing. The default input is always real; take it over failing.
            guard deviceID != nil && allowDeviceFallback else { throw error }
            Self.logger.error("input device \(deviceID!) unusable (\(error, privacy: .public)) — falling back to the system default")
            teardownEngine()
            try buildEngine(deviceID: nil)
        }
    }

    private func buildEngine(deviceID: UInt32?) throws {
        // A fresh engine every time, never one held across sessions. AVAudioEngine caches
        // the format of the input hardware it was attached to, and a long-lived instance
        // goes on reporting the format of a microphone that has since been unplugged —
        // which is precisely the disagreement that makes `installTap` raise.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Pin the selected input device BEFORE reading the format — a non-default mic can have a
        // different native sample rate/channel count, and the tap must match the device we'll
        // actually capture from. Throwing here is clean: no tap is installed yet.
        #if os(macOS)
        if let deviceID, let audioUnit = inputNode.audioUnit {
            var id = deviceID
            let err = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if err != noErr {
                throw RecognitionError.engineStartFailed(NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to set input device"]))
            }
        }
        #endif

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // channelCount 0 (mic not ready / no input device) passes a sampleRate-only check,
        // so guard both before handing the format to AVFoundation.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw RecognitionError.engineStartFailed(NSError(
                domain: "SpeechRecognitionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid audio format"]
            ))
        }

        // Capture references for the tap callback
        let levelCont = levelContinuation
        let audioBufferCont = audioBufferContinuation
        let timestampedAudioCont = timestampedAudioContinuation
        let inputBuilder = inputContinuation
        let converter = bufferConverter
        let targetFormat = analyzerFormat
        let heartbeat = self.heartbeat
        let backup = self.backup
        let captureStamps = captureStampContinuation
        // Boxed in the closure rather than kept on the actor: the tap runs off-actor, and
        // one counter per engine is exactly the lifetime we want anyway.
        var levelBufferCount = 0
        // This audio bus serializes its tap callback. Count the actual converted
        // frames fed to AnalyzerInput, not asynchronously consumed raw packets.
        var analyzerAudioOffset = 0.0

        let tap: AVAudioNodeTapBlock = { buffer, time in
            heartbeat.beat()

            // Feed converted audio to the analyzer
            if let targetFormat, let converter {
                do {
                    let converted = try converter.convertBuffer(buffer, to: targetFormat)
                    guard let owned = CapturedAudioBuffer.copy(converted, at: time)?.buffer else { throw RecognitionError.recognitionUnavailable }
                    let length = Double(converted.frameLength) / converted.format.sampleRate
                    if case .dropped = inputBuilder?.yield(AnalyzerInput(buffer: owned, bufferStartTime: CMTime(seconds: analyzerAudioOffset, preferredTimescale: 1_000_000_000))) {
                        captureStamps?.yield(.init(audioStart: analyzerAudioOffset, duration: 0, hostStart: 0, discontinuity: true))
                    }
                    if time.isHostTimeValid {
                        captureStamps?.yield(.init(audioStart: analyzerAudioOffset, duration: length,
                            hostStart: AVAudioTime.seconds(forHostTime: time.hostTime)))
                    } else {
                        captureStamps?.yield(.init(audioStart: analyzerAudioOffset, duration: 0, hostStart: 0, discontinuity: true))
                    }
                    analyzerAudioOffset += length
                } catch {
                    Self.logger.error("buffer conversion error: \(error)")
                    captureStamps?.yield(.init(audioStart: analyzerAudioOffset, duration: 0, hostStart: 0, discontinuity: true))
                }
            }

            backup?.write(buffer)

            // Forward raw audio buffer for camera recording
            audioBufferCont?.yield(buffer)
            if let captured = CapturedAudioBuffer.copy(buffer, at: time) {
                timestampedAudioCont?.yield(captured)
            }

            // Compute RMS level for mic indicator (throttled)
            levelBufferCount += 1
            if levelBufferCount % 2 == 0, let level = RMSCalculator.rmsLevel(from: buffer, scalingFactor: 10) {
                levelCont?.yield(level)
            }
        }

        do {
            try inputNode.installTapSafely(onBus: 0, bufferSize: 4096, format: recordingFormat, block: tap)
        } catch {
            throw RecognitionError.engineStartFailed(error)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTapSafely(onBus: 0)
            throw RecognitionError.engineStartFailed(error)
        }

        audioEngine = engine
        heartbeat.reset()
    }

    private func teardownEngine() {
        guard let engine = audioEngine else { return }
        audioEngine = nil
        engine.stop()
        // Removing a tap from a node whose hardware has gone away is itself a raise risk.
        engine.inputNode.removeTapSafely(onBus: 0)
    }

    /// Stop recognition and release resources. Call when session ends.
    /// - Returns: the backup recording's URL, if one was requested and captured enough audio
    ///   to be worth transcribing. The caller owns it, including deleting it.
    @discardableResult
    public func stopRecognition() async -> URL? {
        let finishingAnalyzer = analyzer
        return await withTaskCancellationHandler {
            await endRecognition(discardingResults: false)
        } onCancel: {
            // Target the analyzer that was being finalized, never a replacement
            // session that may start after this stop returns.
            Task { await finishingAnalyzer?.cancelAndFinishNow() }
        }
    }

    /// Stop capture immediately and discard pending analyzer results. The caller
    /// still owns the returned recovery file and decides its deletion policy.
    @discardableResult
    public func cancelRecognition() async -> URL? {
        await endRecognition(discardingResults: true)
    }

    private func endRecognition(discardingResults: Bool) async -> URL? {
        sessionActive = false
        teardownEngine()
        let backupURL = backup?.finish()
        backup = nil

        // Finish the input stream to signal end of audio
        inputContinuation?.finish()
        inputContinuation = nil

        // Finalize the analyzer
        if let analyzer {
            if discardingResults || Task.isCancelled {
                resultsTask?.cancel()
                await analyzer.cancelAndFinishNow()
            } else {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }

        // Drain remaining results so the last committed segment isn't dropped.
        // Bounded: cancel the results task if it hasn't finished within 2 seconds.
        if let task = resultsTask {
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                task.cancel()
            }
            try? await task.value
            timeout.cancel()
        }
        resultsTask = nil

        // Finish transcript, level, and audio buffer streams
        transcriptContinuation?.finish()
        transcriptContinuation = nil
        levelContinuation?.finish()
        levelContinuation = nil
        audioBufferContinuation?.finish()
        audioBufferContinuation = nil
        timestampedAudioContinuation?.finish()
        timestampedAudioContinuation = nil
        captureStampContinuation?.finish()
        captureStampContinuation = nil

        // Deactivate audio session (iOS/visionOS only)
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // Clean up state
        transcriber = nil
        analyzer = nil
        analyzerFormat = nil
        bufferConverter = nil
        requestedDeviceID = nil

        return backupURL
    }
}
