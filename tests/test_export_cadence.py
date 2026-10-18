"""Encoded frame identities, rather than advertised frame-rate metadata, are the oracle."""
import json
import os
from pathlib import Path
import subprocess
import wave

import numpy as np
import pytest

import config as C
import fcpxml as FX
import timeline_derivatives as D


def coded_movie(path, count=32, audio=False):
    # Eight wide monochrome bars encode the frame ordinal. No private media.
    frames = np.empty((count, 128, 256, 3), np.uint8)
    for ordinal in range(count):
        for bit in range(8):
            frames[ordinal, :, bit*32:(bit+1)*32] = 220 if ordinal & (1 << bit) else 28
    sound = []
    if audio:
        samples = np.concatenate([(.03+.01*i)*np.sin(2*np.pi*1200*np.arange(2002)/48000)
                                  for i in range(count)])
        pcm = path.with_suffix('.wav')
        with wave.open(str(pcm), 'wb') as writer:
            writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(48000)
            writer.writeframes((samples*32767).astype('<i2').tobytes())
        sound = ['-i', str(pcm), '-c:a', 'pcm_s16le']
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1',
        '-f', 'rawvideo', '-pixel_format', 'rgb24', '-video_size', '256x128',
        '-framerate', C.FPS_STR, '-i', '-', *sound,
        '-t', str(count/C.FPS), '-frames:v', str(count),
        '-c:v', 'libx264', '-threads', '2', '-crf', '0', '-pix_fmt', 'yuv420p',
        '-video_track_timescale', '24000', '-n', str(path)],
        input=frames.tobytes(), capture_output=True, check=True, timeout=30)
    return path


def decoded_ordinals(path):
    # Sample bar centres after the real fit/encode/decode path, away from edges.
    result = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1',
        '-i', str(path), '-vf', 'scale=256:144', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
        capture_output=True, check=True, timeout=60)
    pixels = np.frombuffer(result.stdout, np.uint8).reshape(-1, 144, 256, 3)
    levels = pixels[:, 72, np.arange(8)*32+16].mean(axis=-1)
    assert np.all((levels < 65) | (levels > 185)), 'Frame code became ambiguous.'
    return ((levels > 128) * (1 << np.arange(8))).sum(axis=1).tolist()


def assert_frame_clock(path, count):
    probe = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_streams', '-show_frames', '-show_entries',
        'stream=time_base,r_frame_rate,duration_ts:frame=best_effort_timestamp',
        '-of', 'json', str(path)], capture_output=True, check=True, timeout=60).stdout)
    stream = probe['streams'][0]
    assert stream['time_base'] == '1/24000'
    assert stream['r_frame_rate'] == C.FPS_STR
    assert [int(f['best_effort_timestamp']) for f in probe['frames']] == [i*1001 for i in range(count)]
    assert int(stream['duration_ts']) == count*1001


def test_many_one_frame_edits_keep_every_selected_source_frame(tmp_path):
    source = coded_movie(tmp_path/'frame-coded.mov', audio=True)
    choices = [(i*7) % 32 for i in range(96)]
    clips = [FX.Clip(source, i/C.FPS, ordinal/C.FPS, 1/C.FPS)
             for i, ordinal in enumerate(choices)]
    clips.append(FX.Clip(source, 96/C.FPS, 8/C.FPS, 8/C.FPS))
    expected = choices + list(range(8, 16))
    parent = tmp_path/'parent.fcpxml'
    builder = FX.FCPXMLBuilder('Synthetic one-frame edit cadence')
    builder.write(builder.build(clips, []), parent)
    before = D.sha(parent), D.sha(source)
    output = D.derive(parent, tmp_path/'cadence', aspect='16:9', resolution='720p')
    assert decoded_ordinals(output) == expected
    assert_frame_clock(output, len(expected))
    receipt = json.loads((output.parent/'derivative.json').read_text())
    verification = json.loads((output.parent/'decode-verification.json').read_text())
    assert receipt['picture_cadence_verified']
    assert verification['picture_cadence']['frame_count'] == len(expected)
    assert D.sha(output.parent/'decode-verification.json') == receipt['output_sha256']['decode-verification.json']
    audio_info = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
        '-show_entries', 'stream=time_base,duration_ts', '-of', 'json', str(output)],
        capture_output=True, check=True).stdout)['streams'][0]
    assert audio_info['time_base'] == '1/48000'
    assert int(audio_info['duration_ts']) == len(expected)*2002
    pcm = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(output),
        '-f', 'f32le', '-ac', '1', '-'], capture_output=True, check=True).stdout
    samples = np.frombuffer(pcm, '<f4')
    # AAC boundary ringing is excluded; each middle window must retain its
    # selected source amplitude, without cumulative short-clip audio drift.
    rms = [np.sqrt(np.mean(samples[i*2002+600:i*2002+1400]**2)) for i in range(len(expected))]
    assert np.allclose(rms, [(.03+.01*i)/np.sqrt(2) for i in expected], atol=.012)
    assert before == (D.sha(parent), D.sha(source))


def test_actual_millisecond_clock_is_rejected(tmp_path):
    source = coded_movie(tmp_path/'exact.mov', 8)
    assert D.verify_picture_clock(source, 8)['verified']
    wrong = tmp_path/'millisecond.mov'
    D.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(source), '-c', 'copy',
           '-video_track_timescale', '1000', '-n', str(wrong)])
    with pytest.raises(ValueError, match='cadence'):
        D.verify_picture_clock(wrong, 8)


def test_missing_final_picture_is_not_held_or_published_as_complete(tmp_path):
    source = coded_movie(tmp_path/'short.mov', 3)
    parent = tmp_path/'parent.fcpxml'
    builder = FX.FCPXMLBuilder('Synthetic missing final picture')
    builder.write(builder.build([FX.Clip(source, 0, 0, 4/C.FPS)], []), parent)
    folder = tmp_path/'refused'
    with pytest.raises(ValueError):
        D.derive(parent, folder, aspect='16:9', resolution='720p')
    assert not (folder/'derivative.json').exists()


@pytest.mark.parametrize('connected', [False, True])
def test_long_audio_tail_cannot_hide_short_selected_video(tmp_path, connected):
    short = coded_movie(tmp_path/'short.mov', 3)
    extended = tmp_path/'long-audio-tail.mov'
    D.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(short), '-f', 'lavfi',
        '-i', 'anullsrc=r=48000:cl=stereo', '-t', str(12/C.FPS), '-c:v', 'copy',
        '-c:a', 'pcm_s16le', '-video_track_timescale', '24000', '-movie_timescale', '24000',
        '-n', str(extended)])
    assert FX.probe(extended)['duration'] > 11/C.FPS
    assert float(D.picture_duration(extended)) == pytest.approx(3/C.FPS, abs=1e-9)
    parent = tmp_path/'parent.fcpxml'
    builder = FX.FCPXMLBuilder('Synthetic misleading audio tail')
    if connected:
        base = coded_movie(tmp_path/'base.mov', 16)
        clips, layers = [FX.Clip(base, 0, 0, 16/C.FPS)], [
            FX.Connected(extended, 5/C.FPS, 8/C.FPS, video_only=True)]
    else:
        clips, layers = [FX.Clip(extended, 0, 0, 8/C.FPS)], []
    builder.write(builder.build(clips, layers), parent)
    before = D.sha(parent), D.sha(extended)
    folder = tmp_path/'refused-tail'
    with pytest.raises(ValueError, match='selected video range'):
        D.derive(parent, folder, aspect='16:9', resolution='720p')
    assert not folder.exists()  # refusal before rendering or publishing a receipt
    assert before == (D.sha(parent), D.sha(extended))


def test_video_packet_bound_supports_container_without_stream_duration(tmp_path):
    source = coded_movie(tmp_path/'exact.mov', 8)
    container = tmp_path/'no-stream-duration.mkv'
    D.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(source), '-c', 'copy', '-n', str(container)])
    duration = float(D.picture_duration(container))
    assert 8/C.FPS <= duration <= 8/C.FPS+.001
    parent = tmp_path/'parent.fcpxml'
    builder = FX.FCPXMLBuilder('Synthetic packet-clock input')
    builder.write(builder.build([FX.Clip(container, 0, 0, 8/C.FPS)], []), parent)
    output = D.derive(parent, tmp_path/'packet-clock', aspect='16:9', resolution='720p')
    assert decoded_ordinals(output) == list(range(8))
    assert_frame_clock(output, 8)


def test_change_after_video_inspection_invalidates_source_identity(tmp_path, monkeypatch):
    source = coded_movie(tmp_path/'mutable-synthetic.mov', 8)
    parent = tmp_path/'parent.fcpxml'
    builder = FX.FCPXMLBuilder('Synthetic change during admission')
    builder.write(builder.build([FX.Clip(source, 0, 0, 8/C.FPS)], []), parent)
    inspect = D.picture_duration
    def changed_after_inspection(path):
        duration = inspect(path)
        # A valid free atom changes identity without damaging playable picture.
        with path.open('ab') as handle: handle.write(b'\x00\x00\x00\x08free')
        return duration
    monkeypatch.setattr(D, 'picture_duration', changed_after_inspection)
    folder = tmp_path/'changed-source'
    with pytest.raises(ValueError, match='source changed during export'):
        D.derive(parent, folder, aspect='16:9', resolution='720p')
    assert not (folder/'derivative.json').exists()


def test_connected_movie_has_exact_start_end_and_source_ordinals_through_offline_bridge(tmp_path):
    source = coded_movie(tmp_path/'frame-coded.mov', 48)
    parent = tmp_path/'parent.fcpxml'
    builder = FX.FCPXMLBuilder('Synthetic connected movie timing')
    builder.write(builder.build([FX.Clip(source, 0, 0, 40/C.FPS)],
        [FX.Connected(source, 12/C.FPS, 8/C.FPS, start=3/C.FPS, video_only=True)]), parent)
    before = D.sha(parent), D.sha(source)
    folder = tmp_path/'offline export'
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run([str(root/'run'), 'timeline_derivatives.py', str(parent), str(folder),
        '--aspect', '16:9', '--resolution', '720p'], cwd=root,
        env={**os.environ, 'CLAUTO_OFFLINE': '1'}, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout)['state'] == 'complete'
    expected = list(range(40))
    expected[12:20] = range(3, 11)
    assert decoded_ordinals(folder/'review.mp4') == expected
    assert_frame_clock(folder/'review.mp4', 40)
    assert before == (D.sha(parent), D.sha(source))
