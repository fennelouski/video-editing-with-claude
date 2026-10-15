# Direct region dictation

Select a paused-frame mark and choose **Dictate This Region**. Clauto handles local
speech setup in the app: microphone and speech consent, local model preparation
with progress, and the current default microphone on first use. Its embedded
VoiceKit integration has no separate Dictate app prerequisite. A previously
selected disconnected device does not silently fall back; choose an available
microphone in this editor. Capture itself never requests permission or installs
assets. Real permission/model/microphone execution remains untested under the
current background-only restriction.

Before capture starts, a project-local record binds the session to the original
project/version/movie provenance, exact paused frame, verified frozen PNG,
normalized region snapshot and draft identity. Later selection changes never
retarget this session. Project-wide ordinary voice capture drains before region
capture acquires the shared provider; that provider also enforces one owner.

Delivered raw speech revisions retain original segment IDs, text, partial/final
status, audio times and character timing runs. A hash envelope and serialized
compare-and-swap updates protect the ledger; completed sessions cannot be
rewritten. Recognition corrections update the original region while its note
still equals the previous projection. Typing, undo or region deletion takes
precedence permanently for that capture; later words stay in original-word
history. Recognition does not assign person IDs or turn a spoken name into an
identity link. Explicit typed mention choices remain available.

**Save Frame Comment** automatically turns off capture and drains final results
before taking the immutable comment snapshot. There is no required finalize
button. **Microphone Off** is a privacy control and also saves available finals.
Cancel similarly drains and retains raw evidence while discarding the editable
comment draft. **Open Dictated Region** in saved-version feedback can recover
its exact PNG, original mark and raw transcript after cancellation or restart.
A prepared/recording record found after restart is incomplete history, not a
claim that the microphone is currently running or its result final.

The editable note and raw ledger remain distinct. Saved shapes link stable
session IDs; saving checks their exact original frame/region bindings. A failed
storage update keeps delivered words in memory, shows the pending words, stops
capture, and blocks close until retry succeeds. Earlier ledger bytes and saved
comments remain intact. The original project's physical root is checked for
all reads and writes. No video, source media, approval, production authorization
or external AI request is created by dictation.

Limits are explicit: 1024 recognition revisions/session, 16 KiB per raw text,
4096 character timing runs/result, 3 MiB decoded/4 MiB encoded ledger, 16 MiB
frozen PNG, 64 session links/mark and 4096 session directories/project. Over-limit
or malformed input refuses publication and remains pending; it is never silently
truncated. Region note limits still apply independently. This bounded checkpoint
does not implement unlimited continuous recording, automatic session rollover,
spoken-name disambiguation or arbitrary conversation.

Verification uses generated video and mocked speech/permissions only. Native
layout, actual microphone/model behavior, VoiceOver and real NAS acceptance
remain pending. This source increment does not complete live conversation or the
graphics/cutout/font work.

Review corrections: note editing/removal and undo/redo advance a separate user-edit identity; restoring identical words never re-enables projection or relinking. The Save control and backend share one admission predicate, including final-only capture. A store-owned synchronous region-capture lease prevents cross-window setup/finish cycles; the second region waits for an explicit retry after the current region saves or turns its microphone off. No pairwise controller drain is used.

Regression harness correction: the existing blocked-reader capacity test now requires each admission precondition before issuing its saturation probe, with fresh bounded deadlines for admission/release and deferred gate cleanup. A missed admission fails and releases the synthetic gate instead of queuing the probe behind it. The v2 full-run stall/sample remain preserved; this correction alone does not establish a production fault or prove the stall causal chain. Production Swift bytes remain identical to v2.
