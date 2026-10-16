import SwiftUI

struct LiveConversationView: View {
    @Bindable var controller: LiveConversationController
    let legacyRequests: [LocalMessage]
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading,spacing: compact ? 10:16) {
            HStack {
                ClautoIcon(.conversation,size: 18)
                Text("Work with Claude").font(ClautoDesign.type(16,weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if controller.connected || controller.connecting {
                    Button(controller.connecting ? "Cancel Connection":"Disconnect") { Task { await controller.disconnect() } }.font(ClautoDesign.caption)
                }
            }
            ScrollView {
                VStack(alignment: .leading,spacing: 14) {
                    if let document = controller.document {
                        ForEach(document.messages) { message in
                            VStack(alignment: .leading,spacing: 6) {
                                Text("You").font(ClautoDesign.caption)
                                Text(message.text).textSelection(.enabled)
                                if let edit = message.localEdit {
                                    Text("Local command · saved v\(edit.target.versionNumber)").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                                }
                                ForEach(document.turns.filter { $0.messageIDs.last == message.id }) { turn in
                                    Text("Claude").font(ClautoDesign.caption)
                                    if !turn.text.isEmpty { Text(turn.text).textSelection(.enabled) }
                                    else if turn.state == .running { ClautoActivity(label: "Thinking… Keep sending feedback as you go.") }
                                    Text(turn.state.rawValue.capitalized).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                                    if let failure = turn.failure { Text(failure).font(ClautoDesign.caption).textSelection(.enabled) }
                                }
                                if document.queued.contains(where: { $0.id == message.id }) {
                                    Text("Queued · included in the next reply").font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
                                }
                            }
                            ClautoRule()
                        }
                        if let packet = document.packets.last {
                            Text("Feedback packet saved · \(packet.messageIDs.count) messages · review only")
                                .font(ClautoDesign.caption).textSelection(.enabled)
                        }
                    }
                    if !legacyRequests.isEmpty {
                        ClautoDisclosure("Earlier local requests") {
                            Text("These were saved without sending to Claude. They remain local.").font(ClautoDesign.caption)
                            ForEach(legacyRequests) { request in Text(request.text).textSelection(.enabled) }
                        }
                    }
                    if let recovered = controller.document?.recoveredDrafts, !recovered.isEmpty {
                        ClautoDisclosure("Recovered Unsent Drafts") {
                            ForEach(recovered) { entry in
                                Text(entry.draft.text).textSelection(.enabled)
                                Button("Continue This Draft") { Task { await controller.continueRecoveredDraft(entry.id) } }
                                    .disabled(controller.resolvingDraft || controller.submitting)
                                ClautoRule()
                            }
                        }
                    }
                }
            }.frame(minHeight: compact ? 70:140,maxHeight: compact ? 150:.infinity)
            if let updates = controller.localUpdates { ConversationLocalUpdatesView(controller: updates) }
            ClautoField(label: "Message",text: Binding(get: { controller.draft.text },set: controller.edit),placeholder: "What should change?",axis: .vertical)
                .lineLimit(2...5).accessibilityIdentifier("liveConversationComposer")
            HStack {
                ClautoAction("Send",icon: .conversation,kind: .primary) { Task { _ = await controller.submit() } }
                    .disabled(!controller.canSend).accessibilityIdentifier("sendLiveConversation")
                if controller.storagePending || controller.draftDirty {
                    Button("Retry Saving") { Task { await controller.retryStorage() } }.disabled(controller.savingDraft)
                }
                if controller.draftConflict {
                    Button("Keep Both Drafts") { Task { await controller.keepBothDrafts() } }
                        .disabled(controller.resolvingDraft || controller.submitting || controller.savingDraft)
                }
                if controller.canRetryReply {
                    Button("Retry Reply") { Task { await controller.retryReply() } }.disabled(controller.connecting || controller.disconnecting)
                }
                if controller.needsSignIn {
                    Button("Sign In to Continue") { Task { await controller.signIn() } }.disabled(controller.connecting)
                } else if !controller.connected, !(controller.document?.queued.isEmpty ?? true) {
                    Button("Connect and Continue") { Task { await controller.connect() } }.disabled(controller.connecting)
                }
            }
            if let notice = controller.localEditNotice { Text(notice).font(ClautoDesign.caption).textSelection(.enabled) }
            if let detail = controller.connectionDetail { ClautoActivity(label: detail) }
            if controller.preparingReply { ClautoActivity(label: "Preparing your saved feedback…") }
            if let error = controller.error { Text(error).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled) }
            Text("Only messages you send here are shared with Claude. Footage, transcripts and frame notes stay local. Keep steering; idle feedback is saved together automatically.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
        }.padding(compact ? 18:22).task { await controller.load() }
    }
}

/// Status stays beside the composer, so the user can keep steering while a
/// separately saved local export runs. No SwiftUI/native instantiation in tests.
private struct ConversationLocalUpdatesView: View {
    @Bindable var controller: ConversationLocalEditController
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text("Local cut updates").font(ClautoDesign.caption).accessibilityAddTraits(.isHeader)
            Text("Send a command such as ‘make it portrait at 720p’, ‘trim from 1:12 to 1:30’, or ‘use the full cut’. After two quiet minutes, supported commands are combined into a new export. Other feedback stays in your conversation.")
                .font(ClautoDesign.caption).foregroundStyle(ClautoDesign.quiet)
            if controller.running {
                ClautoActivity(label: "Updating your cut locally… You can keep sending feedback.")
                Button("Stop This Export") { controller.stopCurrent() }
            } else if controller.nextUpdateAt != nil {
                Text("Waiting for a quiet moment before the next local update.").font(ClautoDesign.caption)
            }
            if let latest = controller.ledger?.jobs.last,let state = latest.state {
                Text("Saved v\(latest.request.target.versionNumber) · \(latest.request.output.aspect == "9:16" ? "Portrait":"Landscape") · \(latest.request.output.resolution.rawValue) · \(state.rawValue.capitalized)")
                    .font(ClautoDesign.caption).textSelection(.enabled)
                if let detail = latest.events.last?.detail { Text(detail).font(ClautoDesign.caption).textSelection(.enabled) }
                if state == .succeeded {
                    Text(controller.latestMatchesFeedback ? "Your new video is in Exports. Its saved parent cut is unchanged.":"An earlier export is saved. Your newer feedback is still being collected.").font(ClautoDesign.caption)
                }
            }
            if controller.canRetryExport { Button("Retry Local Export") { Task { await controller.retryExport() } } }
            if let error = controller.error {
                Text(error).font(ClautoDesign.caption).foregroundStyle(ClautoDesign.ember).textSelection(.enabled)
                Button("Retry Saving Local Work") { Task { await controller.retrySaving() } }.disabled(controller.running)
            }
        }.accessibilityIdentifier("conversationLocalUpdates")
    }
}
