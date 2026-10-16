import Foundation
import Darwin

/// Local job history is independent of the text-only provider. An idle batch
/// consumes only exact, source-bound commands explicitly submitted in the app.
actor ConversationLocalEditRepository {
    private struct Envelope: Codable { let sha256: String;let payload: Data }
    let project: Project
    init(project: Project) { self.project = project }
    private func read(_ state: SourceRenderDirectory) throws -> ConversationLocalEditLedger {
        guard try CreativeAssetFiles.exists("local-edit-jobs.json",in: state) else { return .init(project: project.id) }
        let envelope = try CreativeAssetFiles.decode(state.read("local-edit-jobs.json",limit: 16*1024*1024),as: Envelope.self)
        guard envelope.payload.count<=12*1024*1024,TranscriptSourceMap.sha(envelope.payload)==envelope.sha256 else { throw ProjectFailure.invalidProject }
        let ledger = try CreativeAssetFiles.decode(envelope.payload,as: ConversationLocalEditLedger.self)
        try ledger.validate(project: project.id);return ledger
    }
    func load() throws -> ConversationLocalEditLedger {
        let root = try ProjectMutationLease.checkedRoot(project),state = try root.child(".clauto")
        let value = try read(state);try root.checkPath();try state.checkPath();return value
    }
    private func mutate(_ edit: (inout ConversationLocalEditLedger,LiveConversationDocument) throws -> Void) throws -> ConversationLocalEditLedger {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let state = try lease.root.child(".clauto"),encoder = CreativeAssetFiles.encoder()
        var ledger = try read(state);let oldBytes = try encoder.encode(ledger)
        let conversation = try LiveConversationRepository.localEditingSnapshot(state,project: project.id)
        try edit(&ledger,conversation);try ledger.validate(project: project.id)
        guard try encoder.encode(ledger) != oldBytes else { return ledger }
        ledger.revision += 1;try ledger.validate(project: project.id)
        let payload = try encoder.encode(ledger),bytes = try encoder.encode(Envelope(sha256: TranscriptSourceMap.sha(payload),payload: payload))
        guard payload.count<=12*1024*1024,bytes.count<=16*1024*1024 else { throw WorkflowFailure.invalid("The local edit history is full. Existing feedback and exports remain saved.") }
        try lease.root.checkPath();try state.checkPath();try state.replacePointer(bytes,name: "local-edit-jobs.json")
        try lease.root.checkPath();try state.checkPath();return ledger
    }
    private func terminal(_ state: ConversationLocalEditLedger.Event.State,owner: UUID? = nil,detail: String? = nil,export: DerivedCut? = nil,now: Date) -> ConversationLocalEditLedger.Event {
        .init(state: state,created: now,ownerID: owner,ownerPID: owner==nil ? nil:getpid(),detail: detail.map { String($0.prefix(1024)) },exportID: export?.id,recipeSHA256: export?.recipeSHA256)
    }
    func recover(now: Date = Date()) throws -> ConversationLocalEditLedger {
        try mutate { ledger,_ in
            for index in ledger.jobs.indices where ledger.jobs[index].state == .running {
                let pid = ledger.jobs[index].events.last?.ownerPID ?? 0
                if pid>0,kill(pid,0)==0 || errno==EPERM { continue }
                ledger.jobs[index].events.append(terminal(.cancelled,detail: "The earlier local worker ended before completion. Its request and partial output remain saved.",now: now))
            }
        }
    }
    func enqueueIdle(now: Date = Date(),idleInterval: TimeInterval = 120) throws -> ConversationLocalEditLedger {
        guard idleInterval.isFinite,(0...86400).contains(idleInterval) else { throw ProjectFailure.invalidProject }
        return try mutate { ledger,conversation in
            guard let latest = conversation.latestActivity,now.timeIntervalSince(latest)>=idleInterval,
                  conversation.draft?.text.isEmpty != false,!conversation.messages.isEmpty,
                  let latestTarget = conversation.messages.last(where: { $0.localEdit != nil })?.localEdit?.target else { return }
            let frontier = conversation.messages.map(\.id)
            guard !ledger.jobs.contains(where: { $0.request.sessionID==conversation.sessionID && $0.request.feedbackIDs==frontier }) else { return }
            // A later command on another cut starts a fresh local sequence. Older
            // messages remain history and can never be silently retargeted.
            let lastForeign = conversation.messages.lastIndex(where: { message in
                guard let target = message.localEdit?.target else { return false };return target != latestTarget
            }) ?? -1
            let commands = conversation.messages.dropFirst(lastForeign+1).filter { $0.localEdit?.target==latestTarget }
            guard !commands.isEmpty else { return }
            var output = latestTarget.initialRequest
            for message in commands {
                guard let instruction = message.localEdit else { throw ProjectFailure.invalidProject }
                try instruction.validate(text: message.text,project: project.id)
                for patch in instruction.patches { output = try patch.applying(to: output,target: latestTarget) }
            }
            let request = ConversationLocalEditRequest(schemaVersion: 1,projectID: project.id,sessionID: conversation.sessionID,
                feedbackIDs: frontier,commandIDs: commands.map(\.id),textSHA256: Dictionary(uniqueKeysWithValues: commands.map { ($0.id.uuidString,TranscriptSourceMap.sha(Data($0.text.utf8))) }),target: latestTarget,output: output)
            try request.validate(project: project.id)
            for index in ledger.jobs.indices where ledger.jobs[index].state == .queued {
                ledger.jobs[index].events.append(terminal(.superseded,detail: "New feedback replaced this waiting batch. Its request remains in history.",now: now))
            }
            let hash = TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(request))
            ledger.jobs.append(.init(id: UUID(),request: request,requestSHA256: hash,created: now,
                events: [terminal(.queued,now: now)]))
        }
    }
    func retry(_ id: UUID,now: Date = Date()) throws -> ConversationLocalEditLedger {
        try mutate { ledger,conversation in
            guard let earlier = ledger.jobs.last,earlier.id==id,let state = earlier.state,[.failed,.cancelled].contains(state),
                  earlier.request.sessionID==conversation.sessionID,earlier.request.feedbackIDs==conversation.messages.map(\.id),
                  conversation.draft?.text.isEmpty != false else {
                throw WorkflowFailure.invalid("New feedback is waiting. Its next quiet batch will use the newer instructions.")
            }
            ledger.jobs.append(.init(id: UUID(),request: earlier.request,requestSHA256: earlier.requestSHA256,created: now,events: [terminal(.queued,now: now)]))
        }
    }
    func claim(_ id: UUID,owner: UUID,now: Date = Date()) throws -> ConversationLocalEditLedger {
        try mutate { ledger,conversation in
            guard let index = ledger.jobs.firstIndex(where: { $0.id==id }) else { throw ProjectFailure.invalidProject }
            if ledger.jobs[index].state == .running,ledger.jobs[index].events.last?.ownerID==owner,ledger.jobs[index].events.last?.ownerPID==getpid() {
                if ledger.jobs[index].request.sessionID != conversation.sessionID || ledger.jobs[index].request.feedbackIDs != conversation.messages.map(\.id) || conversation.draft?.text.isEmpty == false {
                    ledger.jobs[index].events.append(terminal(.superseded,owner: owner,detail: "New feedback superseded the unacknowledged local claim.",now: now))
                };return
            }
            guard ledger.jobs[index].state == .queued else { throw ProjectFailure.invalidProject }
            guard !ledger.jobs.contains(where: { $0.state == .running }) else { throw WorkflowFailure.invalid("Another local edit is still finishing. New feedback stays queued.") }
            guard ledger.jobs[index].request.sessionID==conversation.sessionID,
                  ledger.jobs[index].request.feedbackIDs==conversation.messages.map(\.id),conversation.draft?.text.isEmpty != false else {
                ledger.jobs[index].events.append(terminal(.superseded,detail: "Newer feedback is waiting for its idle batch.",now: now));return
            }
            ledger.jobs[index].events.append(terminal(.running,owner: owner,now: now))
        }
    }
    func finish(_ id: UUID,owner: UUID,export: DerivedCut? = nil,cancelled: Bool = false,failure: String? = nil,admission: ConversationLocalEditAdmission? = nil,now: Date = Date()) throws -> ConversationLocalEditLedger {
        try mutate { ledger,conversation in
            guard let index = ledger.jobs.firstIndex(where: { $0.id==id }),
                  let previous = ledger.jobs[index].events.last,previous.ownerID==owner,previous.ownerPID==getpid() else { throw ProjectFailure.invalidProject }
            // A failed acknowledgement cannot turn an already saved terminal
            // event back into a running attempt or publish a different result.
            if previous.state != .running {
                switch previous.state {
                case .succeeded: guard !cancelled,previous.exportID==export?.id,previous.recipeSHA256==export?.recipeSHA256 else { throw ProjectFailure.invalidProject }
                case .failed: guard export==nil,!cancelled else { throw ProjectFailure.invalidProject }
                case .cancelled: guard cancelled || admission?.cancelled == true else { throw ProjectFailure.invalidProject }
                case .superseded: break
                default: throw ProjectFailure.invalidProject
                };return
            }
            let request = ledger.jobs[index].request
            if cancelled || admission?.cancelled == true || Task.isCancelled {
                ledger.jobs[index].events.append(terminal(.cancelled,owner: owner,detail: "New steering stopped this local attempt. Earlier exports and words remain saved.",now: now));return
            }
            guard request.sessionID==conversation.sessionID,request.feedbackIDs==conversation.messages.map(\.id),conversation.draft?.text.isEmpty != false else {
                ledger.jobs[index].events.append(terminal(.superseded,owner: owner,detail: "New feedback arrived before this batch completed. Any completed export remains a separate earlier result.",now: now));return
            }
            if let export {
                guard export.projectID==project.id,export.parentVersionID==request.target.versionID,
                      export.parentTimelineSHA256==request.target.timelineSHA256,export.request==request.output,
                      CutoutSourceInfo.validHash(export.recipeSHA256) else { throw ProjectFailure.invalidProject }
                ledger.jobs[index].events.append(terminal(.succeeded,owner: owner,detail: "Verified local export saved. Its parent cut remains unchanged.",export: export,now: now))
            } else {
                ledger.jobs[index].events.append(terminal(.failed,owner: owner,detail: failure ?? "The local edit did not complete. Its request remains saved for retry.",now: now))
            }
        }
    }
}
