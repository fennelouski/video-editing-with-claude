# Reviewed movie candidates

This increment extends [voice review](VOICE_REVIEW.md) from instruction artifacts to
explicitly approved frame cuts and a separately verified candidate movie. It is a
bounded review mode, not production authorization or a camera-layer editor.

## Using it

1. Open a saved version in Cut and choose **Use this player for Voice Review**.
2. Enter a typed review note with start/end seconds and **Remove range** or
   **Protect range**, or choose **Start listening**. Clauto guides permission,
   input and on-device speech setup inside the app. Reopening never records.
3. Complete commands such as **cut from 1:12 to 1:16**, **keep the previous five
   seconds**, or **remove from here for two seconds** can propose a range locally.
   The proposal is separate from your original comment and timestamp. For typed
   feedback, **Use times from comment** fills the visible fields for review.
4. Keep steering while playback or local work continues. Cards and original speech
   timing save continuously. After 120 seconds without new feedback, an immutable
   packet starts local proposal preparation. **Mic Off** is a privacy control;
   stopping is not a processing prerequisite. Resolve unclear meaning or timing.
5. Review the exact proposed frame ranges. Removals round inward and protections
   outward to full 24000/1001 frames. Half-open ranges use the watched version
   before ripple edits; protections and conflicting requests block approval.
6. **Approve and create preview** saves the exact plan approval and starts one
   verified local render. Subsequent feedback invalidates stale proposals. Rendering
   never replaces a saved cut or changes its current pointer.
7. **Play verified review candidate** opens the candidate with its own Feedback
   panel. Listening may continue through the switch; a hard clock boundary marks
   the transition. New speech and typed notes retain the candidate's identity and
   candidate-local time, rather than being reassigned to its original parent.
   A further approved plan can produce a second candidate from this movie.
   Closing returns feedback ownership to the paused original player when it still
   exists. The app never silently starts a new recording during playback changes.

`script/launch_pizza_review.sh` builds this canonical checkout and opens the
separately imported Pizza Yeast v7 project using the task-local verified import
receipt. The receipt records movie SHA, exact project/version and engine path.
There is no fallback to a different checkout or a guessed newer revision.

## Exact supported scope

The editable candidate FCPXML references the **watched rendered master**. Its
fragments bind parent version, master SHA, original parent-frame ranges and new
ripple offsets. The verbatim original FCPXML and raw approved inputs remain saved
as reference lineage. Camera, graphics, titles and science elements in that native
parent are **not independently edited or revalidated**. No new editorial, science,
fact, graphics, duration or production approval is implied.

The importer copies only explicitly selected verified movie, original native XML,
script, plan, brief and technical receipt into a new NAS review-only project. The
movie's SHA, technical-pass boolean, exact original path, frame count and duration
must agree with actual AVFoundation timing. Only MP4 review imports are currently
supported. A compound resource sequence cannot override the one top-level project
sequence. Imported projects refuse normal production Run, and their script JSON
is not relabeled as a newly approved human script/PDF.

## Byte and storage contract

The existing source-span renderer and its two-source/2 MiB synthetic contract are
unchanged. Videos SMB still cannot satisfy that renderer's unlink attestation.
This separate contract supports one selected master up to **1 GiB**, 86,400 parent
frames, 64 explicit operations and 32 retained fragments.

The master snapshot uses an exclusively created, owner-only **local APFS** temporary
directory. A separate read-only descriptor is opened and the snapshot unlinked
before copying; nlink must remain zero. Bounded copy, SHA and source descriptor/path
identity checks surround decoding. A per-user flock serializes master copies; child
decoders inherit the lease. No mutable-original decoding fallback is permitted.
The directory is removed only if still the same owned empty directory. All durable
projects, receipts, parts, candidates and publication copies remain on the NAS.

Peak NAS output allowance is **8 GiB**, including parts, final output, possible SMB
publication copy and metadata reserve. Failed evidence remains in its own staging
folder and never becomes a current preview. Each artifact is streamed, bounded,
SHA checked and synced outside the voice ledger lock, then committed using short
identity checks. Exclusive rename is preferred; SMB ENOTSUP uses an exclusive UUID
folder and exclusive descriptor-relative copies.

Input support is unrotated, square-pixel, 8-bit YUV420P SDR Rec.709 video at
24000/1001 with a zero-start presentation clock, plus zero-start 48 kHz mono/stereo
audio. Missing/unknown color tags, HDR/10-bit/display transforms, gaps/overlaps and
unsupported clocks refuse;
there is no hidden resampling, padding or clock repair. H.264 B-frame reordering
and AAC priming are checked through decoded presentation timestamps. Final output
is lossless H.264 plus PCM16 MOV. Every fragment's decoded YUV420P8 pixels and PCM16
samples must match the frozen master exactly; final concatenation is checked again.
This is decoded-content equality, not original compressed packet equality.

The pinned worker emits its final proof SHA through captured stdout. Native code
requires that exact proof, all fixed artifacts/hashes/sizes, independently expected
plan/approval/input/lineage and full FCPXML structure, actual movie duration and
unchanged parent inputs. Rehashing a modified proof and movie cannot mint a native
completion. A stored completion and hashes are checked again before playback.

## Acceptance and remaining work

Generated red/green/blue and tone fixtures exercise real decoding, native approval,
NAS publication, source preservation, exact frames/samples and refusal paths.
Actual v7 is imported for review only; no private candidate edit is invented.
Earlier imported-player receipts are scoped to their original builds. The integrated
M10 app has not been launched during the foreground hold. Task-local receipts give
exact background build/test counts and source hashes; candidate-player interaction,
live speech and accessibility acceptance remain unobserved.

Real microphone/recognition timing, native candidate-player interaction, interactive VoiceOver, camera/graphics-layer
application and production byte attestation remain unfinished. AVPlayer opens a
mutable NAS pathname after check-time validation; fingerprints do not make later
playback immutable. No distribution, notarization, remote provider, media upload,
Final Cut control or remote Git publication is part of this increment.

M10 inherited-protection correction: earlier protected original frames project
through each candidate's verified retained fragments as separate constraints.
Original note text, onset, target and revision are untouched. A child removal
cannot overlap these constraints; revise the source protection and create a new
source candidate to change it. Native provenance recomputes the projection, and
the renderer separately checks inherited constraints against parent lineage.
Each opening is cancellation/generation owned, so navigation during verification
cannot seize a feedback clock after its surface has closed.

## Spoken command interpretation

The local English interpreter accepts a complete timed remove/protect command,
including numeric clocks, seconds/minutes, common zero-to-ninety-nine number words
and decimal seconds. Previous/next ranges measure from original speech onset.
It does not interpret vague phrases, negations, alternatives, compound commands,
quotes of source narration, speed, camera, graphics or science edits. Unsupported
requests stay available for clarification. No range is clamped into the movie.
Manually selected complete ranges/actions override the command interpretation.
An exact plan approval remains required before producing a separate preview.
