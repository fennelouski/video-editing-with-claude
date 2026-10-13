"""
Stage 1 — Transcription.

Runs WhisperX over the footage to produce word-level timestamps. Everything downstream
(the rough cut, the caption timing, the graphic sync) keys off this file, so it runs first
and it runs on the *original* audio, never on a re-encode.

Output: build/transcripts/<clip>.words.json
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import cli
import config as C


VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".m4v", ".avi", ".mts", ".m2ts", ".mxf"}
AUDIO_EXTS = {".wav", ".aif", ".aiff", ".flac", ".m4a", ".mp3"}


@dataclass
class Word:
    word: str
    start: float
    end: float
    score: float = 0.0
    speaker: str | None = None


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def extract_audio(src: Path, dst: Path) -> Path:
    """Pull a clean 16k mono WAV for the ASR pass. Never touches the master audio."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-y", "-i", str(src),
        "-vn", "-ac", "1", "-ar", "16000",
        "-c:a", "pcm_s16le",
        str(dst),
    ]
    proc = _run(cmd)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg audio extraction failed for {src.name}:\n{proc.stderr[-800:]}")
    return dst


def transcribe(
    audio: Path,
    model: str = C.WHISPER_MODEL,
    language: str = "en",
    device: str = "auto",
    diarize: bool = False,
) -> dict:
    """
    Call WhisperX. Prefers the Python API; falls back to the CLI if the import shape differs
    between versions (whisperx's API has moved around).
    """
    try:
        import whisperx  # type: ignore
    except ImportError:
        return _transcribe_cli(audio, model, language, device)

    if device == "auto":
        try:
            import torch  # type: ignore
            device = "cuda" if torch.cuda.is_available() else "cpu"
        except ImportError:
            device = "cpu"

    compute_type = "float16" if device == "cuda" else "int8"

    print(f"  loading whisper model '{model}' on {device} ({compute_type})")
    options = {"local_files_only": True} if os.environ.get("CLAUTO_OFFLINE") == "1" else {}
    asr = whisperx.load_model(model, device, compute_type=compute_type, language=language, **options)
    audio_data = whisperx.load_audio(str(audio))
    result = asr.transcribe(audio_data, batch_size=8)

    print("  aligning for word-level timestamps")
    align_model, meta = whisperx.load_align_model(
        language_code=result.get("language", language), device=device
    )
    result = whisperx.align(
        result["segments"], align_model, meta, audio_data, device,
        return_char_alignments=False,
    )

    if diarize:
        print("  diarizing")
        try:
            dia = whisperx.DiarizationPipeline(device=device)
            result = whisperx.assign_word_speakers(dia(str(audio)), result)
        except Exception as exc:  # noqa: BLE001 - diarization is optional
            print(f"  ! diarization skipped: {exc}")

    return result


def _transcribe_cli(audio: Path, model: str, language: str, device: str) -> dict:
    """Fallback path: shell out to the whisperx CLI and read its JSON."""
    if os.environ.get("CLAUTO_OFFLINE") == "1":
        raise RuntimeError("The local WhisperX API is required for offline cuts. Complete model setup before retrying.")
    if not shutil.which("whisperx"):
        raise RuntimeError(
            "whisperx is not importable and not on PATH.\n"
            "  Activate the venv, then:  pip install whisperx"
        )
    out_dir = C.TRANSCRIPTS / "_whisperx_cli"
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        "whisperx", str(audio),
        "--model", model,
        "--language", language,
        "--output_format", "json",
        "--output_dir", str(out_dir),
    ]
    if device != "auto":
        cmd += ["--device", device]
    proc = _run(cmd)
    if proc.returncode != 0:
        raise RuntimeError(f"whisperx CLI failed:\n{proc.stderr[-800:]}")
    produced = out_dir / f"{audio.stem}.json"
    return json.loads(produced.read_text())


def flatten_words(result: dict) -> list[Word]:
    """WhisperX nests words inside segments. Flatten and drop anything without timing."""
    words: list[Word] = []
    for seg in result.get("segments", []):
        for w in seg.get("words", []):
            text = (w.get("word") or w.get("text") or "").strip()
            start, end = w.get("start"), w.get("end")
            if not text or start is None or end is None:
                # WhisperX emits untimed words for unalignable tokens (numerals, symbols).
                # Dropping them is correct: nothing downstream can cut on an unknown boundary.
                continue
            words.append(
                Word(
                    word=text,
                    start=round(float(start), 3),
                    end=round(float(end), 3),
                    score=round(float(w.get("score", 0.0)), 3),
                    speaker=w.get("speaker"),
                )
            )
    return words


def process_clip(
    clip: Path,
    model: str,
    language: str,
    device: str,
    diarize: bool,
    force: bool,
) -> Path | None:
    out_path = C.TRANSCRIPTS / f"{clip.stem}.words.json"
    if out_path.exists():
        prior = json.loads(out_path.read_text()).get("source")
        prior_path = Path(prior) if prior else None
        if prior_path is None or (C.ROOT / prior_path).resolve() != clip.resolve():
            raise RuntimeError(
                f"{out_path} belongs to another source with the same filename; "
                "use a separate build folder for each card/project"
            )
    if out_path.exists() and not force:
        print(f"  = {clip.name} already transcribed (--force to redo)")
        return out_path

    print(f"→ {clip.name}")
    work_wav = C.TRANSCRIPTS / "_audio" / f"{clip.stem}.16k.wav"
    extract_audio(clip, work_wav)

    result = transcribe(work_wav, model=model, language=language, device=device, diarize=diarize)
    words = flatten_words(result)

    if not words:
        print(f"  ! no words recovered from {clip.name} — check the audio track")
        return None

    payload = {
        "clip": clip.name,
        "source": C.path_label(clip),
        "language": result.get("language", language),
        "model": model,
        "fps": C.FPS,
        "word_count": len(words),
        "duration": round(words[-1].end, 3),
        "words": [asdict(w) for w in words],
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2))
    print(f"  ✓ {len(words)} words → {C.path_label(out_path)}")
    return out_path


def find_clips(explicit: list[str] | None) -> list[Path]:
    if explicit:
        return [Path(p).resolve() for p in explicit]
    clips: list[Path] = []
    for sub in ("a-cam", "b-cam", "audio", ""):
        d = C.FOOTAGE / sub if sub else C.FOOTAGE
        if not d.is_dir():
            continue
        for p in sorted(d.iterdir()):
            if p.is_file() and p.suffix.lower() in (VIDEO_EXTS | AUDIO_EXTS):
                clips.append(p)
    return clips


def main(argv: list[str] | None = None) -> int:
    cli.preflight(('whisperx',))
    ap = argparse.ArgumentParser(description="Stage 1 — WhisperX word-level transcription")
    ap.add_argument("clips", nargs="*", help="specific files; default = scan footage/")
    ap.add_argument("--model", default=C.WHISPER_MODEL)
    ap.add_argument("--download-model", choices=("small", "medium", "large-v3"), help="prefetch speech and English alignment models without reading footage")
    ap.add_argument("--language", default="en")
    ap.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    ap.add_argument("--diarize", action="store_true", help="label speakers (needs HF token)")
    ap.add_argument("--force", action="store_true", help="re-transcribe existing")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    if not shutil.which("ffmpeg"):
        print("! ffmpeg not found on PATH", file=sys.stderr)
        return 2

    if args.download_model:
        import whisperx
        whisperx.load_model(args.download_model, "cpu", compute_type="int8", language=args.language)
        whisperx.load_align_model(language_code=args.language, device="cpu")
        print(f"Speech and alignment models ready: {args.download_model}")
        return 0

    clips = find_clips([cli.resolve_or_exit(p, expect=(".mov", ".mp4", ".m4v", ".avi", ".mts", ".m2ts", ".mxf", ".mkv"), label='clip')
                        for p in args.clips])
    if not clips:
        print(f"! no footage found under {C.path_label(C.FOOTAGE)}/")
        print("  drop a clip into footage/a-cam/ and run again")
        return 1

    print(f"Stage 1 — transcribing {len(clips)} clip(s)")
    if args.dry_run:
        for c in clips:
            print(f"  would transcribe: {c.name}")
        return 0

    C.TRANSCRIPTS.mkdir(parents=True, exist_ok=True)
    ok = 0
    for clip in clips:
        try:
            if process_clip(clip, args.model, args.language, args.device, args.diarize, args.force):
                ok += 1
        except Exception as exc:  # noqa: BLE001 - one bad clip shouldn't kill the batch
            print(f"  ! {clip.name}: {exc}", file=sys.stderr)

    print(f"Stage 1 complete — {ok}/{len(clips)} transcribed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
