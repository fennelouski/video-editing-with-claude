"""Local-only camera inventory and candidate audio synchronization, never an edit.

Reads an explicit manifest of media paths. Writes derived mono audio and reports
only to a new output folder. Dates and filenames never establish a match. Scores
are candidates until corroborated by several anchors and visual clap/mouth checks.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
from scipy import signal

RATE = 2000


def normalized_matches(reference, query, rate=RATE, count=3, separation=2.0):
    """Return query start positions within reference, with absolute NCC scores.

    The query is centered and energy-normalized at each candidate location. A
    positive location means its audio occurs later in the reference clip.
    """
    a = np.asarray(reference, dtype=np.float64)
    q = np.asarray(query, dtype=np.float64)
    if len(q) < rate or len(a) < len(q) or not np.isfinite(a).all() or not np.isfinite(q).all():
        return []
    q = q - q.mean()
    energy = np.dot(q, q)
    if energy < 1e-12:
        return []
    cross = signal.fftconvolve(a, q[::-1], mode="valid")
    total = np.r_[0.0, np.cumsum(a)]
    squares = np.r_[0.0, np.cumsum(a*a)]
    window = len(q)
    variance = np.maximum(0, squares[window:] - squares[:-window] - (total[window:] - total[:-window])**2/window)
    denominator = np.sqrt(variance * energy)
    scores = np.divide(np.abs(cross), denominator, out=np.zeros_like(cross), where=denominator > 1e-10)
    peaks = []
    for _ in range(count):
        index = int(np.argmax(scores)); score = float(scores[index])
        if score <= 0:
            break
        peaks.append({"at": index/rate, "score": min(1.0, score)})
        radius = int(separation*rate)
        scores[max(0,index-radius):min(len(scores),index+radius+1)] = 0
    return peaks


def extract(path, destination):
    # No shell, no network, no source modification. Independent .f32 fixtures are
    # small and remain on the same authorized NAS as the footage.
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-map", "0:a:0",
        "-ac", "1", "-af", "highpass=f=120,lowpass=f=850", "-ar", str(RATE),
        "-c:a", "pcm_f32le", "-f", "f32le", "-n", str(destination)], check=True)
    return np.fromfile(destination, dtype="<f4")


def consistent_anchor_candidates(anchors, minimum_score=.25, dominance=1.5, tolerance=.05):
    """Dominant, consistent offsets across nonoverlapping query windows.

    Cross-microphone waveforms need not have high absolute correlation. Requiring
    a dominant peak and agreement across independent windows is more informative
    than an absolute score alone. These remain candidates, never physical
    clap/mouth or frame-drift acceptance. Repeated/ambiguous peaks are withheld.
    """
    votes=[]
    for anchor in anchors:
        if not np.isfinite(anchor['a_start']) or not np.isfinite(anchor['query_seconds']) or anchor['a_start']<0 or anchor['query_seconds']<=0:continue
        peaks=sorted([p for p in anchor['candidates'] if np.isfinite(p['score']) and np.isfinite(p['b_minus_a'])],key=lambda p:p['score'],reverse=True)
        if not peaks or peaks[0]['score']<minimum_score:continue
        if len(peaks)>1 and peaks[0]['score']<dominance*peaks[1]['score']:continue
        peak=peaks[0]
        votes.append({'start':anchor['a_start'],'length':anchor['query_seconds'],
                      'offset':peak['b_minus_a'],'score':peak['score']})
    groups=[]
    for seed in votes:
        near=sorted([v for v in votes if abs(v['offset']-seed['offset'])<=tolerance],key=lambda v:v['start'])
        independent=[]
        for vote in near:
            if not independent or vote['start']>=independent[-1]['start']+independent[-1]['length']:
                independent.append(vote)
        if len(independent)<2:continue
        offset=float(np.median([v['offset'] for v in independent]))
        if any(abs(g['b_minus_a_seconds']-offset)<=tolerance for g in groups):continue
        groups.append({'b_minus_a_seconds':offset,'independent_anchor_count':len(independent),
                       'offset_spread_ms':1000*(max(v['offset'] for v in independent)-min(v['offset'] for v in independent)),
                       'minimum_score':min(v['score'] for v in independent),'physical_sync_approved':False})
    return groups


def probe(path):
    result = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)], capture_output=True, check=True)
    return json.loads(result.stdout)


def audit(manifest, output):
    entries = json.loads(manifest.read_text())["sources"]
    if output.exists():
        raise ValueError("Use a new output folder; existing evidence is preserved.")
    if not entries or len({str(Path(x['path']).resolve()) for x in entries}) != len(entries):
        raise ValueError("Explicit, distinct source paths required.")
    if any(x['camera'] not in ['Canon A candidate', 'ONE R B'] for x in entries):
        raise ValueError("Unknown camera role.")
    for x in entries:
        p=Path(x['path'])
        if not p.is_file(): raise FileNotFoundError(p)
    output.mkdir(parents=True)
    audio_dir=output/'audio'; audio_dir.mkdir()
    records=[]; audio={}
    for index, x in enumerate(entries):
        p=Path(x['path']); before=p.stat(); record=dict(x)
        record.update(size=before.st_size,mtime_ns=before.st_mtime_ns,probe=probe(p))
        destination=audio_dir/f'{index:02d}-{p.stem}.f32'
        audio[index]=extract(p,destination)
        record['derived_audio']=str(destination); record['audio_seconds']=len(audio[index])/RATE
        after=p.stat(); record['source_stat_unchanged']=before.st_size==after.st_size and before.st_mtime_ns==after.st_mtime_ns
        records.append(record)
        print(json.dumps({'extracted':p.name,'seconds':record['audio_seconds']}),flush=True)
    (output/'inventory.json').write_text(json.dumps({'sources':records,'dates_establish_match':False},indent=2))
    matches=[]
    b_indices=[i for i,x in enumerate(records) if x['camera']=='ONE R B']
    for ai, record in enumerate(records):
        if record['camera']!='Canon A candidate':continue
        a=audio[ai]; duration=len(a)/RATE
        anchors=sorted(set([min(4.0,max(0,duration-10)), max(0,duration*.25-5), max(0,duration*.5-5), max(0,duration*.75-5)]))
        for bi in b_indices:
            anchor_results=[]
            for start in anchors:
                query=a[int(start*RATE):int((start+min(10,duration-start))*RATE)]
                peaks=normalized_matches(audio[bi],query)
                anchor_results.append({'a_start':start,'query_seconds':len(query)/RATE,'candidates':[dict(p,b_minus_a=p['at']-start) for p in peaks]})
            matches.append({'a':record['path'],'b':records[bi]['path'],'anchors':anchor_results,'verified':False})
        print(json.dumps({'correlated':Path(record['path']).name}),flush=True)
        (output/'sync-candidates.json').write_text(json.dumps({'sample_rate':RATE,'offset_definition':'B source time = A source time + b_minus_a',
            'automatic_candidates_only':True,'visual_clap_and_mouth_check_required':True,'pairs':matches},indent=2))
    return output


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('manifest',type=Path);ap.add_argument('output',type=Path)
    args=ap.parse_args();print(audit(args.manifest,args.output))


if __name__=='__main__':main()
