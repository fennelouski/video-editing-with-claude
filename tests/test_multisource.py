"""Multiple originals must retain identity, timing and assembled-audio verification."""
import json
import shutil
from fractions import Fraction
from pathlib import Path
from types import SimpleNamespace
from xml.etree import ElementTree as ET

import pytest
import config as C
import fcpxml as FX
import multisource as M
import run_pipeline as R
import stage5_composite as S5
from tools import assemble as A


def records(tmp_path, video):
    sources = [tmp_path / 'first.mov', tmp_path / 'second.mov']
    for p in sources:
        shutil.copyfile(video, p)
    duration = FX.probe(sources[0])['duration']
    return [(p, {'source': str(p), 'words': [{'word': label, 'start': .2, 'end': .4}]},
             {'source': str(p), 'keeps': [{'start': 0, 'end': 1}], 'drops': []}, duration)
            for p, label in zip(sources, ['First', 'Second'])]


def test_ordered_virtual_time_keeps_original_source_identity(tmp_path, video):
    data = records(tmp_path, video)
    edl, transcript, picks = M.compile_sources(list(reversed(data)))
    assert [p['path'] for p in picks] == [data[1][0], data[0][0]]
    assert [p['source'] for p in edl['segments']] == [str(data[1][0]), str(data[0][0])]
    assert [w['word'] for w in transcript['words']] == ['Second', 'First']
    tmap = FX.TimelineMap(edl['keeps'])
    assert tmap.to_timeline(transcript['words'][1]['start']) == pytest.approx(C.snap_seconds(1) + .2)
    assert edl['keeps'][1]['start'] == C.snap_seconds(data[0][3])


@pytest.mark.parametrize('bad', ['duplicate', 'identity', 'overlap', 'nan', 'outside'])
def test_invalid_or_ambiguous_source_edits_are_refused(tmp_path, video, bad):
    data = records(tmp_path, video)
    if bad == 'duplicate': data[1] = data[0]
    if bad == 'identity': data[1][1]['source'] = str(data[0][0])
    if bad == 'overlap': data[0][2]['keeps'].append({'start': .4, 'end': 1.2})
    if bad == 'nan': data[0][2]['keeps'][0]['end'] = float('nan')
    if bad == 'outside': data[0][2]['keeps'][0]['end'] = 9999
    with pytest.raises(ValueError): M.compile_sources(data)


def test_final_timeline_uses_both_originals_and_remaps_second_clip_cue(tmp_path, video, monkeypatch):
    data = records(tmp_path, video)
    edl, transcript, picks = M.compile_sources(data)
    folder = tmp_path / 'plan'; folder.mkdir()
    monkeypatch.setattr(C, 'PLAN_DIR', folder)
    (folder / 'test.plan.json').write_text(json.dumps({'cues': []}))
    path = tmp_path / 'selected.edl.json'; path.write_text(json.dumps(edl))
    out = tmp_path / 'test.fcpxml'
    at = edl['keeps'][1]['start'] + .2
    S5.assemble('test', '16:9', path, [(data[0][0], at, {'id': 'cue2', 'hold': .5, 'text': 'Second'})], out)
    assert FX.validate(out) == []
    root = ET.parse(out).getroot()
    assets = {a.attrib['id']: a.find('media-rep').attrib['src'] for a in root.findall('./resources/asset')}
    clips = root.findall('.//sequence/spine/asset-clip')
    assert [assets[c.attrib['ref']] for c in clips] == [data[0][0].as_uri(), data[1][0].as_uri()]
    assert float(Fraction(clips[1].attrib['start'][:-1])) == 0
    overlay = clips[1].find('asset-clip')
    assert float(Fraction(overlay.attrib['offset'][:-1])) == pytest.approx(C.snap_seconds(.2))
    assert out.with_suffix('.validation.json').exists()


def test_assembly_readback_failure_cannot_produce_combined_edl(tmp_path, video, monkeypatch):
    data = records(tmp_path, video)
    rough, words = tmp_path/'rough', tmp_path/'words'; rough.mkdir(); words.mkdir()
    monkeypatch.setattr(C, 'ROUGHCUT', rough); monkeypatch.setattr(C, 'TRANSCRIPTS', words)
    for source, transcript, edl, _ in data:
        (words/f'{source.stem}.words.json').write_text(json.dumps(transcript))
        (rough/f'{source.stem}.edl.json').write_text(json.dumps(edl))
        (rough/f'{source.stem}.heard.txt').write_text('Verified per-clip fixture')
    spec = tmp_path/'order.json'; spec.write_text(json.dumps({'schema_version': 2, 'sources': [{'source': str(r[0]), 'key': r[0].stem} for r in data]}))
    monkeypatch.setattr(A, 'listen_back', lambda *args: ([{'text': 'Incomplete fixture'}], ['unfinished assembled sentence']))
    with pytest.raises(ValueError, match='assembled audio needs review'):
        M.assemble(spec, 'test', False)
    assert not (rough/M.EDL).exists()
    assert not (words/M.TRANSCRIPT).exists()


def test_pipeline_passes_explicit_assembly_edl_and_transcript():
    args = SimpleNamespace(assembly='/fixture/order.json', project='test', script='/fixture/script.md',
                           aggressive=False, preview=True, aspect='16:9', no_captions=False)
    for stage in R.STAGES[:5]:
        if stage.key not in ('roughcut', 'plan', 'composite'): continue
        actual = R.stage_args(stage, args)
        if stage.key == 'roughcut': assert actual[actual.index('--assembly')+1] == args.assembly
        if stage.key in ('plan', 'composite'): assert actual[actual.index('--transcript')+1] == str(C.TRANSCRIPTS/M.TRANSCRIPT)
        if stage.key == 'composite': assert actual[actual.index('--edl')+1] == str(C.ROUGHCUT/M.EDL)


def test_frame_tolerance_cannot_overlap_next_source_block(tmp_path):
    paths = [tmp_path/'a.mov', tmp_path/'b.mov']
    data = [(p, {'source': str(p), 'words': [{'word': 'Frame', 'start': .9, 'end': 1.04}]},
             {'source': str(p), 'keeps': [{'start': 0, 'end': 1.04}], 'drops': []}, 1.0) for p in paths]
    edl, words, picks = M.compile_sources(data)
    assert edl['keeps'][0]['end'] <= edl['keeps'][1]['start']
    assert words['words'][0]['end'] <= edl['keeps'][1]['start']
    assert picks[0]['end'] == C.snap_seconds(1)
    assert FX.TimelineMap(edl['keeps']).to_timeline(edl['keeps'][1]['start'] + .2) == pytest.approx(C.snap_seconds(1) + .2)


@pytest.mark.parametrize('lines', [[], [{'text': '  '}]] )
def test_empty_assembled_speech_is_not_verified(tmp_path, video, monkeypatch, lines):
    data = records(tmp_path, video)
    rough, words = tmp_path/'rough', tmp_path/'words'; rough.mkdir(); words.mkdir()
    monkeypatch.setattr(C, 'ROUGHCUT', rough); monkeypatch.setattr(C, 'TRANSCRIPTS', words)
    for source, transcript, edl, _ in data:
        (words/f'{source.stem}.words.json').write_text(json.dumps(transcript))
        (rough/f'{source.stem}.edl.json').write_text(json.dumps(edl))
        (rough/f'{source.stem}.heard.txt').write_text('Verified source fixture')
    spec = tmp_path/'order.json'; spec.write_text(json.dumps({'schema_version': 2, 'sources': [{'source': str(r[0]), 'key': r[0].stem} for r in data]}))
    monkeypatch.setattr(A, 'listen_back', lambda *args: (lines, []))
    with pytest.raises(ValueError, match='no verified speech'): M.assemble(spec, 'test', False)
    assert not (rough/M.EDL).exists()


def test_copy_output_key_is_preserved_and_removed_spans_have_local_provenance(tmp_path, video, monkeypatch):
    data = records(tmp_path, video)
    rough, words = tmp_path/'rough', tmp_path/'words'; rough.mkdir(); words.mkdir()
    monkeypatch.setattr(C, 'ROUGHCUT', rough); monkeypatch.setattr(C, 'TRANSCRIPTS', words)
    sources = []
    for index, (source, transcript, edl, duration) in enumerate(data):
        key = f'intake-{index}' # Different from the copied original's filename.
        edl['drops'] = [{'start': 1.1, 'end': 1.2, 'reason': 'fixture gap'}]
        (words/f'{key}.words.json').write_text(json.dumps(transcript))
        (rough/f'{key}.edl.json').write_text(json.dumps(edl))
        (rough/f'{key}.heard.txt').write_text('Verified source fixture')
        sources.append({'source': str(source), 'key': key})
    spec = tmp_path/'order.json'; spec.write_text(json.dumps({'schema_version': 2, 'sources': sources}))
    monkeypatch.setattr(A, 'listen_back', lambda *args: ([{'text': 'Complete synthetic read-back.'}], []))
    M.assemble(spec, 'test', False)
    edl = json.loads((rough/M.EDL).read_text())
    assert edl['drops'][1]['source'] == str(data[1][0])
    assert edl['drops'][1]['source_start'] == 1.1
    assert edl['drops'][1]['start'] > 1.1
