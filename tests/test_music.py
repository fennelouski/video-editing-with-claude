"""
Placing a music bed  [S-022].

The level and the band belong together. "10 dB under the voice" is worthless on its own: a
full-band match sets the gain from bass a phone never reproduces, and on a track that is 85%
sub-200 Hz that put the audible part 7 dB below where the number claimed it was. Nathan reported
he could not hear the music three separate times while the measurement said it was fine.
"""

from __future__ import annotations

import subprocess
import wave
from pathlib import Path

import numpy as np
import pytest

import config as C
import music as M


def tone(path: Path, freqs: list[tuple[float, float]], seconds: float = 3.0,
         rate: int = 48000) -> Path:
    """A file made of stated (frequency, amplitude) components."""
    t = np.arange(int(seconds * rate)) / rate
    x = sum(a * np.sin(2 * np.pi * f * t) for f, a in freqs)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    return path


def test_the_level_is_set_from_the_band_not_the_whole_signal(tmp_path):
    """
    The bass-heavy case that caused the defect. Both tracks carry the same energy in the band
    a laptop speaker reproduces, but the music also carries a large sub-100 Hz component. A
    full-band match would duck it for bass nobody hears; a band-limited one must not.
    """
    voice = tone(tmp_path / "v.wav", [(1000, 0.30)])
    lean = tone(tmp_path / "lean.wav", [(1000, 0.30)])
    bassy = tone(tmp_path / "bassy.wav", [(1000, 0.30), (55, 0.90)])

    g_lean = M.bed_gain(voice, lean, M.MUSIC_UNDER_DB)
    g_bassy = M.bed_gain(voice, bassy, M.MUSIC_UNDER_DB)

    # Tolerance is 1 dB, not tighter: brick-walling bins after a 48k->16k resample leaks about
    # half a dB regardless of the input, so a tighter bound would be testing the FFT. The defect
    # this guards was 7 dB, so the margin is ample either way.
    moved = abs(20 * np.log10(g_bassy / g_lean))
    assert moved < 1.0, f"sub-100 Hz content moved the gain by {moved:.1f} dB"


def test_the_bed_lands_the_stated_distance_under_the_voice(tmp_path):
    voice = tone(tmp_path / "v.wav", [(1000, 0.50)])
    bed = tone(tmp_path / "m.wav", [(1400, 0.50)])
    gain = M.bed_gain(voice, bed, M.MUSIC_UNDER_DB)
    assert 20 * np.log10(gain) == pytest.approx(-M.MUSIC_UNDER_DB, abs=0.7)


def test_the_bed_never_sits_above_the_voice():
    """A sign error here is inaudible in code review and obvious in the room."""
    assert M.MUSIC_UNDER_DB > 0


def test_the_high_pass_is_below_the_measurement_band():
    """Filtering inside the band being measured would invalidate the gain it produced."""
    assert M.MUSIC_HIGHPASS_HZ < M.MUSIC_BAND[0]


def test_silent_music_asks_for_no_gain_rather_than_dividing_by_zero(tmp_path):
    voice = tone(tmp_path / "v.wav", [(1000, 0.50)])
    silence = tone(tmp_path / "m.wav", [(1000, 0.0)])
    assert M.bed_gain(voice, silence, M.MUSIC_UNDER_DB) == 0.0


def test_the_limiter_does_not_double_as_a_normaliser():
    """
    ffmpeg's alimiter auto-levels its output unless told not to, which put the first preview
    2 dB over the channel target and its true peak 1.2 dB over the ceiling.
    """
    import stage2_roughcut as S2
    source = Path(S2.__file__).read_text()
    assert "alimiter" in source, "the preview no longer limits — this test needs rewriting"
    for call in source.split("alimiter=")[1:]:
        assert "level=false" in call.split("[")[0], "alimiter is auto-levelling the preview"


def test_the_preview_ceiling_leaves_room_for_the_codec():
    """
    AAC overshoots what the limiter hands it; the number that matters is the one in the file.
    The overshoot is material-dependent — 0.1 dB on one cut of MVI_0016 and 0.8 dB on the next
    — so a ceiling chosen from a single render drifts out of spec when the cut changes. [S-026]
    """
    assert C.PREVIEW_LIMIT_DBTP < C.TRUE_PEAK_MAX_DBTP, (
        "the limiter has to sit below the ceiling, not on it"
    )
    assert C.CODEC_OVERSHOOT_DB >= 0.8, (
        f"{C.CODEC_OVERSHOOT_DB} dB of headroom is less than the overshoot already observed"
    )


def test_the_dialogue_chain_matches_section_8():
    """§8: "High-pass at 80 Hz, gentle de-ess, 3:1 compression, light limiting.\""""
    assert C.VOICE_HIGHPASS_HZ == 80
    assert C.COMP_RATIO == 3.0


def test_the_compressor_threshold_stays_gentle():
    """
    Her delivery already measures 3.6 LU of range before processing, against the 6-8 LU a
    dialogue compressor exists to pull in. A low threshold squashes a track with nothing to
    squash — at -18 dB the range went to 2.5 LU, which is what §8 calls over-processed.
    """
    assert C.COMP_THRESHOLD_DB >= -14.0, (
        f"{C.COMP_THRESHOLD_DB} dB compresses her whole delivery, not its peaks"
    )


def test_the_high_pass_sits_below_speech():
    """80 Hz is under the male and female fundamental both; higher starts thinning the voice."""
    assert C.VOICE_HIGHPASS_HZ <= 90


def test_the_preview_loudness_defaults_to_the_channel_target():
    """The knob exists for judging at playback level; it must not quietly redefine the master."""
    import stage2_roughcut as S2
    parser_src = Path(S2.__file__).read_text()
    assert 'default=C.TARGET_LUFS' in parser_src, "--loudness no longer defaults to spec"


def test_the_bed_level_matches_section_8():
    """
    §8 carried -20 dB for two phases while the code used a different figure, and nothing caught
    it because nothing compared them. The number itself is a judgement by ear; that the document
    and the code agree on it is not. [S-023], [S-025]
    """
    import re
    import config as C
    from music import MUSIC_UNDER_DB

    text = (C.ROOT / "taste_principles.md").read_text(encoding="utf-8")
    m = re.search(r"Sit the bed \*\*(\d+(?:\.\d+)?) dB\s*\n?\s*under the voice", text)
    assert m, "§8 no longer states the bed level in a form the code can check against"
    assert float(m.group(1)) == MUSIC_UNDER_DB, (
        f"§8 says {m.group(1)} dB under the voice, music.py says {MUSIC_UNDER_DB} — "
        "the document is right and the code is a bug (CLAUDE.md)"
    )
