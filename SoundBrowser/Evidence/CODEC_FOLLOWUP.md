# Ogg capability follow-up — 2026-10-28

Work started at 06:16 UTC and checkpointed before the 07:00 UTC cutoff.
Pan owner was notified; all work was headless. No UI or audio playback ran.
Astra fast mode could not be confirmed through the available controls.

A temporary Ogg/Vorbis probe was encoded from the already verified BSB-2278 WAV
using installed FFmpeg. No library originals, IDs or catalog entries changed.
FFprobe confirmed Vorbis, 48 kHz, mono, 2.034750 seconds. FFmpeg decoded the
entire probe successfully to its null sink. Native AVAudioFile decoding failed
at ExtAudioFileOpenURL with Core Audio error 1685348671. The reproducible
read-only Swift probe is Tools/probe-native-audio.swift; it never calls play.

Fixed a concrete availability inconsistency: a catalog entry marked as an
unsupported format could previously be reported available when its bytes were
WAV. Inspection now verifies bytes/hash first, then refuses unsupported catalog
formats explicitly, with no waveform. Valid WAV availability remains intact.
Eleven package tests pass, including the new mismatch regression.

Full Ogg support is NOT implemented. It needs a bounded external decoder adapter,
explicit decoder discovery, immutable original-byte hash verification, decoded
sample-range checks, and separately keyed PCM caches for envelope/audition/export.
The selected original ID/hash must survive conversion; neither originals nor
catalog hashes should be replaced with proxy hashes. The UI must distinguish
missing decoder from missing library assets. Native availability alone is not
a sufficient capability check on this host. Animated-fade rendering is unchanged.

The branch remains local; no merge, installation, upload or live-project writes.
