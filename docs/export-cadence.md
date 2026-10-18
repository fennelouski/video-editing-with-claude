# Local derivative picture timing

The editor's offline `timeline_derivatives.py` bridge preserves the saved
24000/1001 picture edit grid through intermediate encoding, concatenation and
connected-picture composition. Picture selection remains separate from timing:
a one-frame selection in the saved timeline is retained.

Each intermediate is MOV with H.264 picture and 48 kHz PCM, using a 24000-tick
video clock. Every picture frame spans 1001 ticks and 2002 audio samples. This
avoids the accumulated millisecond rounding of the former Matroska intermediates.
The primary picture clock is established before overlay framesync. Connected
movies receive their own integer frame offset and a half-open visibility range;
their source frame rate is normalized before the offset is applied.

The final MP4 uses the same exact picture clock and a 24000-tick movie header.
After full decoding, an additional gate checks every decoded presentation
timestamp, the exact frame count and the video track duration. A mismatch fails
the export before a complete derivative receipt can be written. The existing
audio peak, source identity, immutable destination and separate editable FCPXML
checks still apply. `decode-verification.json` records the cadence result and is
hash-bound by `derivative.json`; the new receipt fields are additive to schema 1.
Source range admission uses the video stream's own rational duration, with a
packet-timestamp fallback for containers that omit it. A longer audio track cannot
make missing primary or connected picture count as available footage.
The fallback allows one packet-clock tick, capped at 1 ms, for container rounding;
it does not allow an additional timeline frame. Coarser unverified packet clocks
are refused. Source hashes are captured before availability inspection and checked
again after rendering.

Regression coverage uses synthetic frame-coded movies to inspect actual decoded
image ordinals after 96 one-frame cuts and a longer clip. Frame-coded connected
movies exercise exact start/end boundaries through the same offline command used
by the app. A sample-coded tone checks audio continuity and exact audio duration.
Other controls reject a real millisecond-clock movie and refuse missing final
picture rather than publishing a successful derivative. Primary and connected
sources with longer audio tails are both refused before rendering when their
selected picture range exceeds the video stream.

Run these alongside the existing export and composition checks with a disposable
NAS scratch folder:

```sh
./run -m pytest -q tests/test_export_cadence.py \
  tests/test_timeline_derivatives.py tests/test_graphic_composition.py \
  --basetemp /path/to/new-nas-scratch
```

These are automated bridge and media checks. They do not establish native player
playback, subjective editing quality or human approval of the saved selections.
