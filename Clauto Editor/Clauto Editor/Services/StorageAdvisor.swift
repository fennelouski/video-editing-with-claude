import Foundation

protocol StorageAdvising: Sendable {
    func recommend(volumes: [StorageVolume],workload: StorageWorkload) async throws -> StorageAdvice
    func cancel() async
}

private actor StorageAdvisorReply {
    var reply: LiveConversationReply
    init(_ session: UUID) { reply = .init(sessionID: session) }
    func receive(_ text: String) throws { try reply.receive(text) }
    func text() throws -> String {
        guard reply.identified,reply.finished,!reply.failed else { throw ClaudeFailure.incomplete }
        return reply.text
    }
}

/// Reuses only the existing, verified text-only Claude client/account contract.
/// Never signs in, provisions credentials, opens tools, or reads project media.
actor ConnectedStorageAdvisor: StorageAdvising {
    private var transport: ClaudeCLITransport?
    private let runner: any CommandRunning
    private let locate: @Sendable ()->URL?
    init(runner: any CommandRunning = ProcessRunner(),locate: @escaping @Sendable ()->URL? = { ClaudeClientContract.locate() }) { self.runner = runner;self.locate = locate }
    func recommend(volumes: [StorageVolume],workload: StorageWorkload) async throws -> StorageAdvice {
        try workload.validate()
        guard let executable = locate() else { throw ClaudeClientFailure.missing }
        let contract = try await ClaudeClientContract.inspect(executable: executable,runner: runner)
        guard try await ClaudeAccountService(contract: contract,runner: runner).status() == .ready else { throw ClaudeClientFailure.signInRequired }
        let aliases = Dictionary(uniqueKeysWithValues: volumes.enumerated().map { ("disk\($0.offset+1)",$0.element.id) })
        let facts = volumes.enumerated().map { index,v -> [String:Any] in
            ["id":"disk\(index+1)","capacityGroup": "group"+String(volumes.firstIndex(where: { $0.capacityGroup == v.capacityGroup }) ?? index),
             "filesystem":v.filesystem,"totalBytes":v.totalBytes,"availableBytes":v.availableBytes,"local":v.local,
             "medium":v.medium.rawValue,"available":v.available,"writable":v.writable,"performanceBasis":v.performance.basis.rawValue]
        }
        let request: [String:Any] = ["volumes":facts,"estimatedBytesByRole":Dictionary(uniqueKeysWithValues: StorageRole.allCases.map { ($0.rawValue,workload.bytes(for: $0)) }),
            "reserveFraction":workload.reserveFraction,"minimumReserveBytes":Int64(workload.minimumReserveGiB*Double(StorageWorkload.gib))]
        let summary = String(decoding: try JSONSerialization.data(withJSONObject: request,options: [.sortedKeys]),as: UTF8.self)
        let prompt = """
        Recommend storage roles for a video editor from these aggregate drive facts.
        No paths, names, footage, transcripts, credentials or project data are supplied.
        Prefer observed local SSDs for edit databases and active proxy/cache; suitable network drives can hold originals, exports and backup copies when capacity fits. Preserve aggregate reserve within each capacityGroup. No throughput measurement occurred; never claim a measured speed. Explain tradeoffs and same-device backup risk. Do not invent devices, facts, paths, approvals or completed actions.
        Reply with only JSON: {"choices":{"edits":"disk1","originals":"disk2","cache":"disk1","exports":"disk1","backups":"disk2"},"explanation":"...","warnings":["..."]}.
        Facts: \(summary)
        """
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-storage-advisor-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) } // owned empty text-only workspace
        let session = UUID(),owner = UUID(),collector = StorageAdvisorReply(session)
        let transport = ClaudeCLITransport(contract: contract,runner: runner); self.transport = transport
        defer { self.transport = nil }
        try await transport.turn(.init(sessionID: session,resume: false,prompt: prompt,project: workspace,engine: workspace,projectID: owner,textOnlyWorkspace: workspace,textAuthorization: .init(projectID: owner,text: prompt))) { line in try await collector.receive(line) }
        let text = try await collector.text()
        struct Reply: Decodable { var choices: [String:String];var explanation: String;var warnings: [String] }
        let bytes = Data(text.utf8);try TranscriptJSONKeys.validate(bytes)
        let parsed = try JSONDecoder().decode(Reply.self,from: bytes)
        guard parsed.explanation.utf8.count <= 4000,parsed.warnings.count <= 12,parsed.warnings.allSatisfy({ $0.utf8.count <= 1000 }) else { throw ClaudeFailure.incomplete }
        var choices: [StorageRole:String] = [:]
        for (role,disk) in parsed.choices {
            guard let role = StorageRole(rawValue: role),let id = aliases[disk] else { throw ClaudeFailure.incomplete }
            choices[role] = id
        }
        let advice = StorageAdvice(source: .connectedClaude,choices: choices,explanation: parsed.explanation,warnings: parsed.warnings,responseSHA256: TranscriptSourceMap.sha(bytes))
        try StorageRecommendation.validate(advice,volumes: volumes,workload: workload)
        return advice
    }
    func cancel() async { await transport?.cancel(); await runner.cancel() }
}
