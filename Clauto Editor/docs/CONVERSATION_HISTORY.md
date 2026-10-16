# Conversation history rollover

Completed conversation history is saved automatically in earlier sections when the next message is sent. View Earlier Messages reads one local section at a time; Older/Newer switches sections. Recovered unsent drafts in an earlier section can be explicitly continued in a fresh composer draft. Merely viewing or restoring history sends nothing to a provider.

Rollover is a local storage operation. The provider session/workspace stays the same and its verified resume witness is carried forward. Archived messages are not resent, summarized by an AI, or uploaded. This does not reset or extend the provider's own context or account limits.

## Publication and ownership

Before a new submission, a window with at least 128 messages/attempts or 4 MiB encoded payload can roll only if all messages are assigned, no reply is running, the latest reply succeeded, and the saved draft is empty or belongs to the submitted snapshot’s already validated CAS lineage. Pending/offline feedback stays active. Each archive is a bounded exact envelope with a fresh UUID file identity and SHA-256 in the active head. A partial write or abort leaves an unreferenced orphan, so retry can use a fresh name. The archive is read back and its directory synced before the common project lease publishes the one active conversation pointer. The local edit job ledger is not rewritten or rolled.

The conversation's global revision and session identity never reset. New schema2 heads make older schema1-only builds refuse writes. Missing/corrupt latest archive or a mismatched folded checkpoint refuses current reads rather than creating an empty conversation. Archives are immutable; exact late terminal acknowledgements can be verified but cannot change a saved reply.

Drafts and reply callbacks carry a history epoch. Unknown stale drafts conflict and retain their words for Keep Both Drafts. A higher revision typed during its own submission may continue only with the exact consumed base receipt and a fresh saved-draft comparison. An exact submitted retry is acknowledged from its original or next section. Restored recovered words get a fresh ID/current epoch and remain unsent. Initial loading precedes composer availability.

## Editing continuity

A chained SHA-256 binds exact submitted IDs, UTF-8 words and typed local instructions. Local jobs use this global frontier rather than the currently visible message array. The archived checkpoint carries the last exact saved-cut target and deterministic accumulated trim/aspect/resolution request, verified against the linked archive. Current commands fold onto that base; switching saved cuts starts a new sequence, including A → B → A. An old result cannot become current after new feedback. No prose summary authorizes an edit.

## Remaining limits and verification scope

This is completed local-history rollover, not unlimited history or provider session rotation. The active window still refuses growth at512 messages/attempts/packets/draft receipts,12MiB payload/16MiB envelope; a queued or failed latest reply can prevent rollover. Recovered drafts and the separate local-job ledger retain their512-entry limits. Archive references are bounded at4096 and the global revision remains below one million. Archive cleanup/deletion and automatic rollover of unresolved queues or job ledgers are not included.

Background tests cover real repository rollover/reopen, exact archive bytes, stale writes, late reply acknowledgements, interrupted publication, byte pressure, provider resume through a synthetic transport, and a real synthetic local export using archived instructions. They do not establish native UI, VoiceOver, actual provider, microphone, NAS or full-product acceptance. No private footage or transcript is a test fixture.
