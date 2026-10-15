import Foundation
import AVFoundation
import Speech
import VoiceKit
import CoreAudio

struct VoiceInputDevice: Identifiable, Equatable, Sendable {
    let id: String; let name: String; var isDefault = false
}
enum VoiceSetupPhase: String, Sendable {
    case idle, microphone, speech, model, ready, failed
    var working: Bool { [.microphone,.speech,.model].contains(self) }
    var label: String {
        switch self {
        case .idle: "Set up voice review"
        case .microphone: "Allow microphone access"
        case .speech: "Allow speech recognition"
        case .model: "Preparing on-device speech…"
        case .ready: "Voice is ready"
        case .failed: "Voice setup paused"
        }
    }
}
enum VoicePermission: String, Sendable { case authorized, notDetermined, denied }
struct VoiceReviewAccess: Sendable {
    let microphone: VoicePermission
    let speech: VoicePermission
    let installedModel: Bool
    let locale: String
    var canStart: Bool { microphone == .authorized && speech == .authorized && installedModel }
}
enum VoiceDictationEvent: Sendable {
    case speech(VoiceSpeechResult)
    case clock(audioStart: Double, duration: Double, hostStart: Double)
    case level(Float)
    case failure(String)
    case ended
}
protocol VoiceReviewDictating: Sendable {
    func access(locale: String) async -> VoiceReviewAccess
    func devices() async -> [VoiceInputDevice]
    func requestMicrophonePermission() async -> Bool
    func requestSpeechPermission() async -> Bool
    func prepareSpeech(locale: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func start(session: UUID, deviceUID: String, locale: String) async throws -> AsyncStream<VoiceDictationEvent>
    func stop(session: UUID, cancel: Bool) async
}
extension VoiceReviewDictating {
    func prepareSpeech(locale: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let installed = await access(locale: locale).installedModel; try Task.checkCancellation()
        guard installed else { throw WorkflowFailure.invalid("On-device speech could not be prepared. Try again.") }
        progress(1)
    }
}

/// Reuses Dictate's local engine without global hotkeys, insertion, preferences,
/// cleanup/providers or capture-time fallback/prompts. Guided setup explicitly
/// prepares Apple's on-device assets inside this app before capture begins.
actor DictateReviewAdapter: VoiceReviewDictating {
    private var owner: UUID?
    private var service: SpeechRecognitionService?
    private var tasks: [Task<Void, Never>] = []
    private var continuation: AsyncStream<VoiceDictationEvent>.Continuation?
    private var stopping: Task<Void, Never>?
    private var preparingSpeech = false

    func access(locale: String) async -> VoiceReviewAccess {
        let microphone: VoicePermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .authorized
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        let speech: VoicePermission
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .authorized
        case .notDetermined: speech = .notDetermined
        default: speech = .denied
        }
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale))
        var installed = false
        if let supported {
            let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
            installed = await AssetInventory.status(forModules: [transcriber]) == .installed
        }
        return .init(microphone: microphone, speech: speech, installedModel: installed, locale: supported?.identifier ?? locale)
    }

    func devices() async -> [VoiceInputDevice] {
        var defaultDevice = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,mScope: kAudioObjectPropertyScopeGlobal,mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&defaultDevice)
        return await AudioInputSelection.availableDevices().compactMap { device in
            guard let number = UInt32(device.id), let uid = AudioInputSelection.deviceUID(for: number) else { return nil }
            return VoiceInputDevice(id: uid,name: device.name,isDefault: number == defaultDevice)
        }
    }

    // The app's explicit Get started flow owns these native consent requests.
    func requestMicrophonePermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    func requestSpeechPermission() async -> Bool { await SpeechRecognitionService.requestAuthorization() == .authorized }

    func prepareSpeech(locale: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard owner == nil, !preparingSpeech else { throw WorkflowFailure.invalid("Voice setup is already running. Keep this window open.") }
        preparingSpeech = true; defer { preparingSpeech = false }
        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale))
        try Task.checkCancellation()
        guard let supported = supportedLocale else {
            throw WorkflowFailure.invalid("On-device speech is unavailable for this language on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: supported,preset: .timeIndexedProgressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber]); try Task.checkCancellation()
        if status == .installed { progress(1); return }
        let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]); try Task.checkCancellation()
        guard let request = installation else {
            let installed = await AssetInventory.status(forModules: [transcriber]); try Task.checkCancellation()
            guard installed == .installed else { throw WorkflowFailure.invalid("Speech setup could not finish. Check your connection and try again.") }
            progress(1); return
        }
        let updates = Task {
            while !Task.isCancelled {
                progress(max(0,min(1,request.progress.fractionCompleted)))
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
        defer { updates.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await request.downloadAndInstall(); try Task.checkCancellation()
        } onCancel: { request.progress.cancel() }
        let installed = await AssetInventory.status(forModules: [transcriber]); try Task.checkCancellation()
        guard installed == .installed else { throw WorkflowFailure.invalid("Speech setup could not finish. Try again.") }
        progress(1)
    }

    func start(session id: UUID, deviceUID: String, locale: String) async throws -> AsyncStream<VoiceDictationEvent> {
        guard owner == nil, !preparingSpeech else { throw WorkflowFailure.invalid("Voice is still being prepared. Try again when setup finishes.") }
        owner = id
        let local = SpeechRecognitionService(allowAuthorizationRequest: false, allowModelInstallation: false, allowDeviceFallback: false)
        service = local
        do {
            let permission = await access(locale: locale)
            try Task.checkCancellation()
            guard owner == id, permission.canStart else { throw WorkflowFailure.invalid("Voice review needs explicit Microphone and Speech access plus an already installed local speech model. No permission or model download was started.") }
            guard !deviceUID.isEmpty, let deviceID = AudioInputSelection.deviceID(forUID: deviceUID) else { throw WorkflowFailure.invalid("The selected microphone disconnected. Choose its current device before recording.") }
            let recognition = try await local.startRecognition(locale: Locale(identifier: permission.locale), inputDeviceID: deviceID)
            try Task.checkCancellation()
            guard owner == id else { throw CancellationError() }
            let (stream, output) = AsyncStream<VoiceDictationEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
            continuation = output
            output.onTermination = { [weak self] reason in
                if case .cancelled = reason { Task { await self?.stop(session: id, cancel: true) } }
            }
            tasks = [
                Task { [weak self] in
                    for await result in recognition.transcript {
                        guard !Task.isCancelled else { break }
                        let segment: String
                        if let start = result.start, start.isFinite, start >= 0, start < 86_400 { segment = "audio-\(Int64((start * 1_000_000).rounded()))" }
                        else { segment = "untimed-" + UUID().uuidString }
                        await self?.emit(.speech(.init(segmentID: segment, text: result.text, isFinal: result.isFinal, audioStart: result.start, audioEnd: result.end,runs: result.runs?.map { .init(utf16Start: $0.utf16Start,utf16Length: $0.utf16Length,audioStart: $0.start,audioEnd: $0.end) })), owner: id)
                    }
                    await self?.transcriptEnded(owner: id)
                },
                Task { [weak self] in
                    for await stamp in recognition.captureStamps {
                        guard !Task.isCancelled else { break }
                        if stamp.discontinuity { await self?.emit(.failure("Microphone samples or their clock were lost. Resolve affected notes before preparing a candidate."), owner: id); break }
                        await self?.emit(.clock(audioStart: stamp.audioStart, duration: stamp.duration, hostStart: stamp.hostStart), owner: id)
                    }
                },
                Task { [weak self] in
                    for await level in recognition.level { if Task.isCancelled { break }; await self?.emit(.level(level), owner: id) }
                },
                Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { break }
                        let present = await self?.devices().contains(where: { $0.id == deviceUID }) ?? false
                        let silence = await local.silenceDuration()
                        if !present || silence > 2.5 {
                            await self?.emit(.failure("The selected microphone stopped delivering samples. Start a new session after reconnecting it."), owner: id)
                            break
                        }
                    }
                }
            ]
            return stream
        } catch {
            _ = await local.cancelRecognition()
            if owner == id { owner = nil; service = nil }
            throw error
        }
    }

    private func emit(_ event: VoiceDictationEvent, owner id: UUID) {
        guard owner == id else { return }
        // If a consumer stalls, loss becomes visible instead of shifting timestamps.
        if case .dropped = continuation?.yield(event) { continuation?.yield(.failure("Voice review delivery overflowed. Resolve incomplete notes before processing.")) }
    }

    private func transcriptEnded(owner id: UUID) {
        if owner == id && stopping == nil { emit(.failure("Local speech recognition ended unexpectedly. Saved feedback remains available for editing or retry."), owner: id) }
    }

    func stop(session id: UUID, cancel: Bool) async {
        guard owner == id, let local = service else { return }
        if let stopping { await stopping.value; return }
        // A fresh service belongs to this session alone. The deadline can never
        // cancel a replacement session's analyzer.
        let operation = Task {
            let deadline = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }; _ = await local.cancelRecognition()
            }
            if cancel { _ = await local.cancelRecognition() } else { _ = await local.stopRecognition() }
            deadline.cancel()
            let relays = Array(self.tasks.prefix(3))
            // StopRecognition finishes its streams; consume their buffered finals
            // and clock packets before closing Clauto's outward event stream.
            await VoiceRelayDrain.finish(relays) { [weak self] in
                await self?.emit(.failure("Final speech or capture-clock delivery timed out. Resolve incomplete feedback before preparing a candidate."), owner: id)
            }
            self.finishStop(owner: id)
        }
        stopping = operation
        await operation.value
    }

    private func finishStop(owner id: UUID) {
        guard owner == id else { return }
        for task in tasks { task.cancel() }; tasks = []
        continuation?.yield(.ended); continuation?.finish(); continuation = nil
        service = nil; owner = nil; stopping = nil
    }
}

/// Shared by the real adapter and pure stream tests; cancellation is cooperative.
/// AsyncStream consumers stop on cancellation, including the watchdog deadline.
enum VoiceRelayDrain {
    static func finish(_ relays: [Task<Void, Never>], timeout: Duration = .seconds(2),
                       onTimeout: @escaping @Sendable () async -> Void) async {
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            await onTimeout()
            for task in relays { task.cancel() }
        }
        for task in relays { await task.value }
        deadline.cancel()
    }
}
