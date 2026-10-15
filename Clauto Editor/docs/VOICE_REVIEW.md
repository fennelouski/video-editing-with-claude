# Asynchronous voice review

Development owner: the existing task-5 checkout on Nathans-Mac-Studio.local
(Mac13,2, M1 Ultra,64GB), branch codex/clauto-native-foundation. Source path stays
fixed; no repository relocation or second writer is part of this feature.

## Implementation plan

1. Reuse the dependency-free microphone/recognition subset from Nathan's MIT
   VoiceKit checkout at `/Users/nathanfennel/Documents/GitHub/voicekit`, revision
   `093289b2acbd37f3851d9583b6da0dc4800f0832`. Keep license and exact source hashes.
   A local package under `ThirdParty/VoiceKit` avoids Dictate's unrelated app,
   updater, diarization and remote cleanup dependencies. Clauto owns its settings.
2. Add `Models/VoiceReview.swift`: immutable version/media/timeline/approved-input
   provenance; capture/sample clock spans; playhead/seek/pause/version events;
   stable note identities and transcript edits; conflict/candidate states.
3. Add `Services/VoiceReviewRepository.swift` and controller: atomic durable ledger,
   project lock, recovery, generation-checked ASR and processing, serialized local
   candidate preparation and debounced render intent. Persist finalized notes
   before dispatch. Never overwrite a reviewed cut or change cuts/current.
4. Add `Services/DictateReviewAdapter.swift`: explicit permission/device preflight,
   installed on-device assets only, no model download or remote cleanup. Bind
   recognition timestamps to authoritative converted audio frame offsets and
   source host times at the audio callback. Do not count asynchronously delivered
   raw buffers or assign timestamps at ASR completion.
5. Integrate `Views/VoiceReviewView.swift` into the existing VersionReview player
   in `Views/ProjectView.swift`. Project-owned controller ownership outlives version-view
   replacement; an explicit player selection prevents comparison players from
   competing for the review clock. Expose microphone Start/Stop/device, live/final/edit history,
   anchor resolution, processing status/cancel/retry and candidate review.
6. Test mocked races and persistence with no microphone activation. Independently
   review exact sources and build the native app before handoff.

## Required behavior

| Requirement | Contract |
|---|---|
| Capture consent | No recording at launch, reopen, test or device enumeration. Start is explicit; microphone/Speech permission requests are separate visible actions. Never accept system permission automatically. |
| Existing local capability | Reuse VoiceKit's device UID selection, safe audio engine and SpeechAnalyzer path. Disable its implicit authorization request, model installation and selected-device fallback for Clauto. No Dictate preference mutation. |
| Speech-onset anchor | Map ASR audio start through synchronously captured converted-frame/host-time spans into confirmed playhead history for the exact saved version. No completion-time fallback, clamping missing data or guessed host epoch. |
| Free transport | Record seek request/completion, play/pause, version attach/detach and capture gaps. Speech crossing a seek, uncertain gap or version switch needs explicit anchor resolution. A delayed result cannot follow the newly selected version. |
| Durable notes | Stable session/segment/note IDs; immutable onset provenance; separate original ASR, user text and edit/history revisions. Persist before processing. Recover interrupted sessions without restarting a microphone. |
| Fast preparation | Finalized anchored notes enter local candidate preparation immediately while capture continues. Serialize conflicting feedback, protect likes, expose unclear/conflicting requests, and debounce costly render intents. Candidate work checks note revision and cancellation before commit. |
| Parent protection | Candidate instructions have a new identity and exact parent hashes/approved craft inputs. They never overwrite the reviewed cut, approved script/plan, project preferences or current pointer. No note is treated as scientific or production approval. |
| Rendering | Existing source, NAS, editorial, facts, graphics, duration and render gates retain their meaning. A prepared candidate is not a rendered/verified new cut. No automatic paid/provider execution. |
| Lifecycle | Explicit stop, cancel/retry, view/project exit and quit release capture ownership and drain durable writes. Late ASR or processor results cannot revive a cancelled/revised note or earlier session. |
| Accessibility | Native labeled buttons/pickers/editors, stable note IDs, keyboard focus, readable state/conflict text and accessible playhead actions. Automated semantic checks supplement, not replace, interactive VoiceOver acceptance. |

## Validation and boundaries

Acceptance must cover late/duplicate/out-of-order ASR, delayed/dropped clock packets,
seeks and version changes during speech, pause, missing timing, stale provenance,
manual edits during processing, cancel/retry, concurrent conflicting notes,
debounce, disk failure/corruption and restart recovery. Tests use mocks and small
synthetic media. Actual microphone recording requires current explicit permission. Authorized
foreground acceptance now includes opening the separately imported latest movie;
this does not authorize starting capture.

The existing synthetic source-span transport remains capability-blocked on Videos
SMB because zero-link attestation is unsupported. The separate
[review-movie candidate contract](VOICE_CANDIDATE_EDITS.md) uses a strict local
unlinked snapshot and persistent NAS output. Later playback still needs version/media revalidation;
voice provenance does not make AVPlayer or editable original references immutable.

## Instruction foundation (15 October; completed before candidate integration)

The native version player now offers **Use this player for Voice Review**, explicit
microphone selection and Start / Stop and Finalize / Cancel capture. Selecting a
comparison player is deliberate, including when two players show the same saved
version. Captured speech uses the chosen player's confirmed history. Native controls
retain labels, semantic state, accessible transcript editors and keyboard actions.
Interactive VoiceOver and real microphone acceptance are still pending.

The project-owned ledger persists version/media/input fingerprints, capture clocks,
transport events, stable transcript identities, original ASR, manual edits/history,
cancellation and candidate states. Editing drafts persist after a short debounce and
survive view replacement/reopen, but do not become instructions before Save. No audio
recording is retained. Failed ingress remains visible and retryable before its
session is closed; shutdown refuses to imply unsaved work was saved. Reopening an
interrupted session does not restart recording. Retry preparation uses saved text;
ASR replay is not offered because no microphone audio is retained.

Finalized, unambiguous notes immediately prepare a new immutable instruction artifact
at `notes/voice-review/candidates/<candidate UUID>.json`. It binds the exact saved
version, note revisions, preview/timeline hashes and approved craft inputs. Likes
remain protection directives. Conflicts require resolution; stale jobs cannot publish
a candidate. A project lease serializes workers, and cancelled batches requeue
unaffected feedback. A two-second debounce records a render intent. This milestone
**does not apply instructions to an edited timeline or render a new movie**. The
renderer integration, actual candidate editing and subsequent local verification
remain unfinished. Existing source/NAS/editorial/facts/graphics gates remain in force.

| Requirement | Result | Evidence / boundary |
|---|---|---|
| Explicit capture, device UID, local installed model | Implemented, mock-tested | No launch/reopen prompt or recording; VoiceKit preflight disallows download and device fallback. Real input remains untested. |
| Speech onset / seek / pause / version provenance | Implemented, mock-tested | Captured frame and host clocks, token-bound player history, explicit resolution for gaps; preview duration must match saved timeline. |
| Stable notes, editing, draft/history retention | Implemented, tested | Atomic hash-checked ledger, process recovery, failed-save replay, stale-edit rejection and durable drafts. |
| Early work while reviewing | Instruction preparation implemented | Independent immutable candidate instructions; no timeline application or movie claimed. |
| Protect/conflict/cancel/retry/serialization | Implemented, tested | Batch cancellation and retry preserve other protection notes; lease and revision checks refuse stale publication. |
| Debounced render | Intent only | Actual candidate application/render/verification remains unfinished and NAS transport remains capability-blocked. |
| Native UI accessibility | Authored / static inspection | Semantic controls and visible resolution/error state; interactive VoiceOver unverified. |
| Local app build | Debug passed; Release verification recorded in handoff | Local ad hoc development signing only; no notarization, distribution or publication. |

Validation artifacts live in the ignored `.artifacts` directory. The final native
suite reports **137 registered cases: 131 passed, six opt-ins skipped**, including
**29 voice-review tests**. These exercise delayed/duplicate ASR, missing clocks,
unannounced seeks, pause/version boundaries, explicit player selection, final stream
drain and timeout, immediate/delayed Start→Stop, stale edits, worker cancellation,
serialized concurrent work, restart recovery, draft retention, candidate tampering,
failed ingress and failed terminal writes. The distinct independent final report
records its own exact-source inventory and tests; consult the handoff for final
review disposition rather than treating this document as an acceptance signature.

Boundaries: no real microphone, permission prompt, model installation, foreground
UI/VoiceOver test, remote AI/provider, private media processing, Sheet edit, Final Cut
control, new cut, current-pointer change, push or deployment occurred. Check-time
fingerprints and duration checks do not make AVPlayer's file descriptor immutable.
Production byte attestation remains a separate existing gate.

## Reviewed candidate integration

[VOICE_CANDIDATE_EDITS.md](VOICE_CANDIDATE_EDITS.md) supersedes the foundation's
“intent only” rendering status for its explicit reduced scope. Typed or finalized
voice notes with a resolved action and range now produce separately approved
parent-frame edits, a verified movie, editable watched-master FCPXML and native
candidate playback. Original camera/graphics XML remains reference-only. NAS
publication passes with an unlinked read-only local APFS snapshot; the old source
renderer gate is unchanged. The exact latest verified v7 is copied into a new
review-only project; no new private edit or production approval is inferred.

See task-local final status and independent review for current validation and
remaining limitations; the foundation test counts above are historical.
