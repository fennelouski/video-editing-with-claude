# Bounded Ogg decode/cache checkpoint — 2026-10-28

Implemented during the authorized work window, headlessly, with Pan's owner
confirming compatibility with their one-thread export. No foreground, playback,
live project, dependency installation, upload or public action occurred.

## Implemented

Integration/decoded_sound_cache.py converts an immutable, hash-verified Ogg
snapshot with an explicitly selected installed FFmpeg. The original asset ID and
SHA remain distinct from the PCM hash. Identity also includes decoder binary and
version fingerprint, decode revision, expected rate/channels/duration. Decoder
identity is rechecked after conversion. Output is PCM16 WAV; no playback occurs.

The caller chooses an existing separate cache root. Input is capped at 64 MiB,
PCM at 128 MiB per entry; expected frame size is checked before conversion.
FFmpeg runs with one thread, a 30-second timeout, local file/pipe protocols,
explicit Ogg demuxer and bounded duration/output size. Cache publication uses a
nonblocking exclusive lock, private staging, descriptor-relative no-symlink reads,
root identity checks and atomic rename. Failed/cancelled preparation cleans its
known staging files. Valid entries are reused after PCM hash/format validation.
There is no whole-library preparation or total-cache eviction policy yet.

The CLI entry point first verifies the bundled catalog, compatibility and license
pins, CC0 redistribution permission, the selected package manifest, membership,
and original size/hash. It returns structured completion/refusal JSON. The output
contains the portable original reference, cache key, receipt hash and PCM receipt.
Its lower-level decode function is for already-authorized snapshots and tests;
it does not itself establish licensing or grant editor availability.

SoundBrowserCore/DecodedSoundCache.swift reads that prepared cache using the
expected decoder and receipt hashes. It verifies original bytes, stable ID,
PCM bytes, actual sample range/rate/channels and the original catalog duration,
then produces a measured WaveEnvelope. It neither enables availability nor plays.

## Verification

10 Python tests pass: real Ogg conversion/reuse, original/proxy identity,
wrong hash/rate/channels/duration/budget, tampered PCM, symlinked roots/files,
busy lock, failed decoder, cancellation cleanup, public-entry refusal and
structured CLI errors. Existing installed FFmpeg only; synthetic codec fixture.

12 Swift package tests pass with CLAUTO_DECODED_CACHE_FIXTURE supplied. The new
cross-language test consumes Python-generated PCM and verifies envelope samples,
original/decoded identity, decoder/receipt pins, traversal and tampered output.
The existing WAV selection/replacement tests remain passing.

Reproduce the bridge fixture with Integration/make_decoded_cache_fixture.py,
passing an explicitly selected local WAV and an isolated output directory. It
creates a synthetic codec-test record, never updates the shipped catalog.
Set CLAUTO_DECODED_CACHE_FIXTURE to that directory when running verify-local.sh.

## Exact boundary / next integration

The native browser still reports Ogg unavailable. This checkpoint does not claim
live Ogg audition, selection or timeline replacement. Native setup needs an
explicit preparation action using the editor ProcessRunner, persistent trusted
receipt pins, cancellation wiring, cache-root selection and decoded/original
snapshot separation. Existing replacement/export validators are WAV-only and
must be extended together before availability can be enabled. A real pinned
catalog Ogg package still needs bounded materialization and positive end-to-end
verification; only synthetic Ogg conversion was exercised here. Animated fades
remain preserved but locally unrenderable under the existing explicit refusal.

Original linked library files and all newer Sol worktrees are untouched. No
owned background workers or descendants are needed after this checkpoint.
Astra fast mode could not be confirmed from this thread's available controls.
