"""
music.py — placing a music bed under narration.

The level and the band it is measured in belong together. "13 dB under the voice" is worthless
on its own: matching *full-band* RMS sets the gain from bass a phone or laptop speaker never
reproduces, which on the first track in use — 85% of its energy below 200 Hz — put the audible
part 7 dB below what the measurement claimed. Nathan reported he could not hear the music three
separate times while the numbers said it was correctly placed.

So both live here, in one module, imported by anything that lays a bed. Copying the constant
without the measurement is the failure this file exists to prevent.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

# Confirmed by ear, measured in MUSIC_BAND. See style_guide [S-022], [S-025].
# 10 dB was audible but sat on top of her; 13 leaves the bed present under the voice.
MUSIC_UNDER_DB = 13.0
MUSIC_BAND = (200.0, 4000.0)

# Sub-90 Hz is felt at best and discarded at worst, but it still consumes the headroom loudnorm
# has to give back — so removing it lets the audible part of the bed sit louder for free.
MUSIC_HIGHPASS_HZ = 90


def bed_gain(voice: Path, music: Path, under_db: float) -> float:
    """
    The gain that puts the bed a stated number of dB under the *speaking* voice.

    Measured from both files rather than dialled in, so changing the voice, the script or the
    track keeps the balance instead of silently altering it.

    This replaced a sidechain compressor, which was the wrong instrument for the job. Ducking
    assumes gaps for the music to breathe in; this narration is continuous with 0.34 s pauses,
    and a 400 ms release never recovers inside one. The bed sat permanently 20 dB below where
    it was meant to and simply could not be heard. A static level has nothing to recover from.
    """
    import numpy as _np

    def pcm(path: Path) -> "_np.ndarray":
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1",
                              "-ar", "16000", "-f", "f32le", "-"],
                             capture_output=True, check=True).stdout
        return _np.frombuffer(raw, dtype="f4")

    def band_rms(x: "_np.ndarray", lo: float, hi: float) -> float:
        spectrum = _np.fft.rfft(x)
        freqs = _np.fft.rfftfreq(len(x), 1 / 16000)
        spectrum[(freqs < lo) | (freqs >= hi)] = 0
        return float(_np.sqrt(_np.mean(_np.fft.irfft(spectrum, len(x)) ** 2)))

    v, m = pcm(voice), pcm(music)
    window = _np.ones(1600) / 1600
    envelope = _np.sqrt(_np.convolve(v ** 2, window, mode="same"))
    # The 60th percentile splits speech from the pauses between lines; averaging across the
    # whole track instead would measure the silences and set the bed far too loud.
    speaking = envelope > _np.percentile(envelope, 60)

    lo, hi = MUSIC_BAND
    v_rms = band_rms(v[speaking], lo, hi)
    m_rms = band_rms(m, lo, hi)
    if m_rms <= 0:
        return 0.0
    return (v_rms / m_rms) * (10 ** (-under_db / 20))


def bed_filter(gain: float, total: float, label_in: str = "1:a",
               label_out: str = "bed") -> str:
    """The ffmpeg chain that turns a music file into a bed: loop, trim to length, high-pass,
    set the measured gain, and fade the ends so it neither starts nor stops abruptly."""
    fade = min(2.0, total / 4)
    return (f"[{label_in}]aloop=loop=-1:size=2e9,atrim=0:{total:.3f},"
            f"highpass=f={MUSIC_HIGHPASS_HZ},volume={gain:.5f},"
            f"afade=t=in:st=0:d={fade:.2f},"
            f"afade=t=out:st={max(0.0, total - fade):.3f}:d={fade:.2f}[{label_out}]")
