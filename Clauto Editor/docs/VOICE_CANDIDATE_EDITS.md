# Reviewed movie candidates

This increment extends [voice review](VOICE_REVIEW.md) from instruction artifacts to
explicitly approved frame cuts and a separately verified candidate movie. It is a
bounded review mode, not production authorization or a camera-layer editor.

## Using it

1. Open a saved version in Cut and choose **Use this player for Voice Review**.
2. Enter a typed review note with start/end seconds and **Remove range** or
   **Protect range**. Alternatively, deliberately start local voice capture, stop
   and finalize, then resolve the note's meaning, range and action. Permission
   prompts and recording require explicit user actions; reopening never records.
3. Save edits. Point-only speech, missing actions, uncertain anchors, unresolved
   conflicts and stale note revisions cannot authorize a removal. Likes become
   protection directives, not removal guesses.
4. Choose **Review exact candidate cuts**. Removals round inward and protections
   outward to full 24000/1001 frames. Displayed half-open frame ranges always use
   the unchanged watched version, before ripple edits. Overlapping removals union;
   overlap with a protection or removal of every frame blocks approval.
5. **Approve these review-movie cuts**, then **Render separate review candidate**.
   Approval binds the exact plan SHA and notes; subsequent feedback invalidates it.
   The renderer is cancellable and cannot replace the watched cut/current pointer.
6. **Play verified review candidate** opens a native in-app player after capture
   is stopped/finalized and the watched player is paused. Candidate playback holds
   a project-wide capture block: it is review-only, without a feedback target.
   Reveal opens its NAS output folder. Verification runs again before handing out
   its URL, and capture/selection are checked again after verification awaits.

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
The graphical launch is waiting for macOS network-volume file-access permission;
no player-ready or playback acceptance is claimed until that permission is granted. Task-local receipts and independent final review give exact test/build
counts, source hashes and launch verification.

Real microphone/recognition timing, interactive VoiceOver, camera/graphics-layer
application and production byte attestation remain unfinished. AVPlayer opens a
mutable NAS pathname after check-time validation; fingerprints do not make later
playback immutable. No distribution, notarization, remote provider, media upload,
Final Cut control or remote Git publication is part of this increment.
