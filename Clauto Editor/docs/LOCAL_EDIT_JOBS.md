# Local conversation edit jobs

Clauto accepts new messages while responding. Supported commands bind at Send to
the saved current cut's UUID, timeline SHA-256, engine version and exact duration.
Their structured metadata stays local and is never appended to the provider prompt.
After 120 quiet seconds, with no nonempty unsent draft, the job controller combines
all explicit local commands in that cut's current command sequence into a separate
DerivedCut export. A later command on another saved cut starts a new sequence.
No Stop and Finalize action is required. Local rendering works independently of
Claude availability; queued or streaming text replies do not block its idle clock.

## Supported commands

The parser accepts complete commands, optionally joined by semicolons/newlines
(up to eight clauses). All clauses must be understood. Examples:

- `make it portrait at 720p` or `make it landscape`
- `trim from 1:12 to 1:30 in portrait at 1080p`
- `use 720p`, `set resolution to 1080p`, or `export at 4k`
- `use the full cut`

Portrait/vertical is 9:16; landscape/horizontal is 16:9. Times are seconds,
minutes:seconds or hours:minutes:seconds. Ranges must fit the exact saved cut and
contain at least one output frame. The last explicit choice of each property wins;
a full-cut command removes an earlier trim. Negated, ambiguous, malformed and
unrecognized clauses remain ordinary conversation feedback. The app labels local
commands separately and does not claim other words have been applied. An unavailable
saved cut keeps the text as feedback and explains that no local command was attached.

These jobs currently trim and reframe/rescale an existing saved cut. They do not
reorder footage, infer semantic edits from replies, identify people, generate facts,
attach arbitrary files, add effects, or implicitly select a graphic/font/cutout.
The separate export workflow can compose an explicitly chosen graphic revision.
Output here uses the existing local timeline bridge and does not change the saved
parent/current cut. Main CutVersion promotion remains unfinished.

## Durable ownership and steering

The common project mutation lease protects the SHA-linked
`.clauto/local-edit-jobs.json` envelope. Each job records the immutable request hash,
submitted feedback frontier, exact command IDs/text hashes and append-only states.
Queued, running, succeeded, failed, cancelled and superseded attempts remain in
history. Only one physical local job may claim a project. A global in-app export
slot also excludes manual derivatives, pipeline work and project checks. Every
attempt has a fresh runner; cancellation cannot stop a later/manual export.

Typing immediately interrupts the owned operation and suspends idle work. The
uncancelled outer worker joins its separately cancelled operation before releasing
the slot or starting a later batch, then saves its terminal record. New feedback
supersedes a late result; any already verified file remains an earlier separate
export. Results appear as current successful updates only after their terminal
acknowledgement. Stop This Export is optional and cancels just that attempt; new
feedback continues normally. Retry Local Export appends the exact failed/cancelled
request only while its feedback frontier is still current. Retry owns a tracked writer before
its first await; quit joins it, duplicate clicks cannot append twice, and its late
acknowledgement cannot resume a paused controller. A tiny per-attempt cancellation
admission is read after the terminal mutation acquires the common lease. New unsent
words therefore invalidate a waiting completion even before draft autosave. A
separate feedback generation check prevents a late saved result from appearing as
current; quit-only pause still joins/saves an already finished result.

Ledger snapshots apply monotonically by revision. Result-save retries share one
tracked writer; duplicate calls join it, quit joins it, and only a matching
completion identity can be cleared after an await. A delayed acknowledgement cannot
clear another attempt's pending result or independently emit a duplicate success.

A failed claim/completion acknowledgement remains in memory, blocks a normal quit
and offers Retry Saving Local Work. Quit joins owned work; cancelled quit can resume
idle scheduling. Dead process owners recover as cancelled without pretending to
have rendered an export. Recovery does not steal a live PID's claim. Forced process
termination can lose unacknowledged in-memory completion; partial files and the
saved request remain. Automatic crash resume/retry is unfinished.

Root descriptor identities are pinned through async operations; replaced project
folders are refused. The actual worker rechecks source version/hash/duration/engine
and uses the production derivative verifier before saving success. Completed output
records pin recipe and parent hashes. Readback revalidates the export rather than
trusting a job's status alone. This is not an adversarial filesystem transaction or
a hard deadline for OS/NAS I/O.

## Bounds and verification

512 jobs, at most four events per job, 12 MiB decoded/16 MiB encoded envelope;
16 KiB text and at most eight clauses. Capacity refuses publication while retaining
prior history. Archival/rollover is unfinished. No credentials, private footage,
provider request, microphone, speech model or app launch is needed by tests.

Model/repository/controller fixtures exercise strict parsing, legacy decoding,
provider-prompt privacy, batching, cancellation/join, slot ownership, exact retry,
root replacement and failed-save recovery. A separate actual-worker test generates
color/tone media, submits through the conversation composer, waits for its idle
controller, renders a small portrait trim through the real worker/Python bridge,
checks dimensions/frame count and verified reopen, and preserves the parent/current
cut and project manifest. These are headless source/synthetic checks. Native UI,
VoiceOver, real speech/provider/NAS/Final Cut and full-product acceptance remain
separate. Immutable receipts define the exact tested source and results.
