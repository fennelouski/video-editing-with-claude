import Foundation
import Observation

/// Store-owned, synchronous admission prevents two windows from building a
/// mutual setup/finish task cycle. The provider remains a second ownership gate.
@MainActor final class RegionDictationAdmission {
    private var owner: UUID?
    func acquire() -> UUID? { guard owner == nil else { return nil }; let id = UUID(); owner = id; return id }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}

/// One explicit capture owns one immutable frame/region. Selection changes do
/// not retarget it. Save and close drain recognition automatically.
@MainActor @Observable final class RegionDictationController {
    enum Mode { case idle, preparing, recording, finishing, failed }
    private(set) var mode: Mode = .idle
    private(set) var phase: VoiceSetupPhase = .idle
    private(set) var progress: Double?
    private(set) var level: Float = 0
    private(set) var devices: [VoiceInputDevice] = []
    private(set) var record: RegionDictationRecord?
    private(set) var history: [RegionDictationRecord] = []
    private(set) var storagePending = false
    var error: String?
    var selectedDeviceUID = ""
    var locale = "en_US"
    @ObservationIgnored let repository: RegionDictationRepository
    @ObservationIgnored private let provider: any VoiceReviewDictating
    @ObservationIgnored private let admission: RegionDictationAdmission
    @ObservationIgnored private var admissionID: UUID?
    @ObservationIgnored private let beforeStart: @MainActor () async -> Bool
    @ObservationIgnored private var setup: Task<Void,Never>?
    @ObservationIgnored private var consumer: Task<Void,Never>?
    @ObservationIgnored private var finishing: Task<Bool,Never>?
    @ObservationIgnored private var persisted: RegionDictationRecord?
    @ObservationIgnored private var projection: (@MainActor (RegionDictationRecord) -> Void)?
    var visibleHistory: [RegionDictationRecord] {
        guard let record else { return history }; return history.filter { $0.id != record.id }+[record]
    }
    var active: Bool { setup != nil || consumer != nil || finishing != nil }
    var hasPendingWork: Bool { active || storagePending }
    init(project: Project,provider: any VoiceReviewDictating,admission: RegionDictationAdmission? = nil,beforeStart: @escaping @MainActor () async -> Bool = { true }) {
        repository = .init(project: project); self.provider = provider; self.admission = admission ?? RegionDictationAdmission(); self.beforeStart = beforeStart
    }
    func load() async {
        do { history = try await repository.list() } catch { self.error = error.localizedDescription }
    }
    func start(frame: FrozenReviewFrame,region: FrameEllipse,draftID: UUID,onChange: @escaping @MainActor (RegionDictationRecord) -> Void) {
        guard !active, !storagePending else { return }
        guard let lease = admission.acquire() else { error = "Another region is listening. Save it or turn its microphone off, then continue here."; return }
        admissionID = lease
        mode = .preparing; error = nil; phase = .microphone; progress = nil; record = nil; persisted = nil
        projection = onChange
        setup = Task { @MainActor [self] in
            defer { setup = nil }
            do {
                guard await beforeStart() else { throw WorkflowFailure.invalid("Earlier voice feedback still needs to save. Retry its storage update before starting this region.") }
                try Task.checkCancellation()
                var access = await provider.access(locale: locale); try Task.checkCancellation()
                if access.microphone != .authorized {
                    guard await provider.requestMicrophonePermission() else { throw WorkflowFailure.invalid("Allow Clauto to use the microphone to dictate this region.") }
                }
                try Task.checkCancellation(); phase = .speech
                access = await provider.access(locale: locale); try Task.checkCancellation()
                if access.speech != .authorized {
                    guard await provider.requestSpeechPermission() else { throw WorkflowFailure.invalid("Allow Clauto speech recognition to continue with on-device dictation.") }
                }
                try Task.checkCancellation(); phase = .model; progress = 0
                try await provider.prepareSpeech(locale: locale) { [weak self] value in
                    guard value.isFinite else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.mode == .preparing, self.phase == .model else { return }
                        self.progress = max(0,min(1,value))
                    }
                }
                try Task.checkCancellation()
                access = await provider.access(locale: locale)
                devices = await provider.devices(); try Task.checkCancellation()
                guard access.canStart else { throw WorkflowFailure.invalid("Voice setup could not finish. Try again here.") }
                // Use the current default on first setup only. A previously
                // chosen/disconnected device never silently falls back.
                if selectedDeviceUID.isEmpty { selectedDeviceUID = (devices.first(where: \.isDefault) ?? devices.first)?.id ?? "" }
                guard devices.contains(where: { $0.id == selectedDeviceUID }) else { throw WorkflowFailure.invalid("The selected microphone is unavailable. Reconnect it and try again.") }
                let initial = RegionDictationRecord(schemaVersion: 1,id: UUID(),draftID: draftID,request: frame.request,region: region,frameSHA256: frame.pngSHA256,width: frame.width,height: frame.height,actualFrameTime: frame.actualTime,locale: access.locale,deviceUID: selectedDeviceUID,created: Date(timeIntervalSince1970: (Date().timeIntervalSince1970*1000).rounded()/1000))
                // The durable anchor and PNG precede microphone capture.
                try await repository.begin(initial,frame: frame)
                record = initial; persisted = initial; publish(initial)
                try Task.checkCancellation()
                let stream = try await provider.start(session: initial.id,deviceUID: initial.deviceUID,locale: initial.locale)
                record?.state = .recording
                phase = .ready; mode = .recording
                consumer = Task { @MainActor in
                    for await event in stream { await receive(event,session: initial.id) }
                    // Do not wait on this consumer from inside itself.
                    if finishing == nil { Task { _ = await self.finish() } }
                }
                try Task.checkCancellation()
            } catch {
                if let record { await provider.stop(session: record.id,cancel: false) }
                if let admissionID { admission.release(admissionID); self.admissionID = nil }
                mode = .failed; phase = .failed
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    private func receive(_ event: VoiceDictationEvent,session: UUID) async {
        guard record?.id == session else { return }
        switch event {
        case .speech(let result):
            // Keep delivered raw revisions even when their storage write fails.
            // Retrying writes the complete pending suffix against the last ack.
            record?.revisions.append(.init(result)); storagePending = true
            do { try await persist() }
            catch { self.error = error.localizedDescription; mode = .failed; Task { _ = await self.finish() } }
        case .failure(let message):
            error = message; record?.failure = message; Task { _ = await self.finish() }
        case .level(let value): if value.isFinite { level = max(0,min(1,value)) }
        case .clock, .ended: break // Exact paused frame is fixed, not a live playhead.
        }
    }
    func chooseDevice(_ uid: String) {
        guard !active, !storagePending, devices.contains(where: { $0.id == uid }) else { return }
        selectedDeviceUID = uid
    }
    private func publish(_ value: RegionDictationRecord) {
        history.removeAll { $0.id == value.id }; history.append(value); projection?(value)
    }
    private func persist() async throws {
        guard let value = record, let previous = persisted else { return }
        storagePending = value != previous
        if storagePending {
            try await repository.update(value,from: previous)
            persisted = value; storagePending = record != persisted
        }
        publish(value)
    }
    @discardableResult func finish() async -> Bool {
        if let finishing { return await finishing.value }
        let operation = Task { @MainActor () -> Bool in
            defer {
                finishing = nil; level = 0
                if let admissionID { admission.release(admissionID); self.admissionID = nil }
            }
            let preparing = setup; preparing?.cancel(); await preparing?.value
            mode = .finishing
            if let record { await provider.stop(session: record.id,cancel: false) }
            await consumer?.value; consumer = nil
            do {
                if var final = record { final.state = final.failure == nil ? .finished:.failed; record = final; try await persist() }
                storagePending = false; mode = .idle; projection = nil; return true
            } catch { storagePending = true; mode = .failed; self.error = error.localizedDescription; return false }
        }
        finishing = operation; return await operation.value
    }
}
