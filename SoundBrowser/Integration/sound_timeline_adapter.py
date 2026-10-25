"""Verified editable-timeline derivative; never edits/adopts the saved parent.

Uses the stable engine reader/writer, frame clock and effects.foley convention.
This adapter does not fabricate a movie/full-decode receipt or editor admission.
"""
from __future__ import annotations
import argparse
from contextlib import contextmanager
import fcntl
from fractions import Fraction
import hashlib
import io
import json
import math
import os
from pathlib import Path
import stat
import sys
import time
import uuid
import wave
from xml.etree import ElementTree as ET

PACKAGE = Path(__file__).resolve().parents[1]
RESOURCES = PACKAGE / 'Sources/SoundBrowserCore/Resources'
CATALOG_SHA = '169d8a73d8464f3435806436e8707126120f08590b0182692ce82c80f8c18e00'
COMPATIBILITY_SHA = '48c5baeacfe4dd0ba14c04cd5c4369b5028a4f00c32d99d200307e6eb3ab1fed'

def sha(data): return hashlib.sha256(data).hexdigest()
def strict(data):
    def pairs(items):
        result = {}
        for key,value in items:
            if key in result: raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    return json.loads(data,object_pairs_hook=pairs,parse_constant=lambda x: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))

def parts(path):
    values = path.split('/')
    if any(x in ('','.','..') for x in values) or any(x in path for x in ('\\',':','\0')): raise ValueError('Unsafe relative path')
    return values

class Directory:
    def __init__(self,path,fd=None):
        original = Path(path)
        self.path = Path(os.path.realpath(original))
        self.fd = os.open(original,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW) if fd is None else fd
        s = os.fstat(self.fd);self.identity = (s.st_dev,s.st_ino)
    def close(self):
        if self.fd >= 0: os.close(self.fd);self.fd = -1
    def check(self):
        s = os.stat(self.path,follow_symlinks=False)
        if not stat.S_ISDIR(s.st_mode) or (s.st_dev,s.st_ino) != self.identity: raise ValueError('Project/output root changed; reopen it')
    def child(self,path,create=False):
        current = os.dup(self.fd)
        try:
            for name in parts(path):
                if create:
                    try: os.mkdir(name,0o700,dir_fd=current)
                    except FileExistsError: pass
                next_fd = os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=current)
                os.close(current);current = next_fd
            result = Directory(self.path/path,current);current = -1;return result
        finally:
            if current >= 0: os.close(current)
    def read(self,path,limit=8*1024*1024):
        values = parts(path);parent = self.child('/'.join(values[:-1])) if len(values)>1 else None
        try:
            fd = os.open(values[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent.fd if parent else self.fd)
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= limit: raise ValueError('Expected a bounded regular file')
                with os.fdopen(os.dup(fd),'rb') as handle: data = handle.read(limit+1)
                after = os.fstat(fd)
                signature = lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
                if len(data)!=before.st_size or signature(before)!=signature(after): raise ValueError('Input changed while reading')
                return data
            finally: os.close(fd)
        finally:
            if parent: parent.close()
    def write_new(self,name,data):
        if len(parts(name)) != 1: raise ValueError('Expected artifact leaf')
        fd = os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=self.fd)
        with os.fdopen(fd,'wb') as handle: handle.write(data);handle.flush();os.fsync(handle.fileno())

@contextmanager
def lease(root):
    state = root.child('.clauto',create=True)
    try:
        fd = os.open('project-mutation.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600,dir_fd=state.fd)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode): raise ValueError('Invalid mutation lock')
            deadline = time.monotonic()+2
            while True:
                try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);break
                except BlockingIOError:
                    if time.monotonic()>=deadline: raise ValueError('Another window is updating this project')
                    time.sleep(.01)
            root.check();state.check();yield
        finally: os.close(fd)
    finally: state.close()

def encode(value): return (json.dumps(value,sort_keys=True,indent=2,allow_nan=False)+'\n').encode()
def identifier(value):
    if str(uuid.UUID(value)).lower()!=value.lower(): raise ValueError('Invalid UUID')
    return value
def integer(value): return type(value) is int and 0<=value<=2**63-1

def insert(project,library,job,*,engine=None,before_publish=lambda:None):
    engine = Path(engine or PACKAGE.parent)
    sys.path.insert(0,str(engine/'scripts'))
    import config as C
    import fcpxml as FX
    import timeline_derivatives as D
    if C.ROOT.resolve()!=engine.resolve(): raise ValueError('Engine source identity mismatch')
    catalog_bytes = (RESOURCES/'catalog.json').read_bytes()
    compatibility_bytes = (RESOURCES/'package-compatibility.json').read_bytes()
    if sha(catalog_bytes)!=CATALOG_SHA or sha(compatibility_bytes)!=COMPATIBILITY_SHA: raise ValueError('Pinned catalog release changed')
    catalog,compatibility = strict(catalog_bytes),strict(compatibility_bytes)
    for record in catalog['licenseRecords']:
        if sha((RESOURCES/record['path']).read_bytes())!=record['sha256']: raise ValueError('License evidence changed')
    request = job['request'];ref = request['reference']
    if job['schemaVersion']!=1: raise ValueError('Unsupported job schema')
    identifier(job['id']);identifier(job['projectID']);identifier(job['parentVersionID'])
    asset = next((a for a in catalog['assets'] if a['id']==ref['assetID']),None)
    if not asset or any(ref.get(k)!=v for k,v in dict(schemaVersion=1,libraryID=catalog['libraryID'],libraryVersion=catalog['version'],assetURI='sfx://asset/'+asset['id'],expectedSHA256=asset['sha256'],license=asset['license'],sourceDurationSeconds=asset['duration'],auditionStatus=asset['auditionStatus']).items()): raise ValueError('Reference does not match pinned catalog')
    if asset['license']!='CC0-1.0' or not asset['redistributionAllowed'] or asset['format']!='wav': raise ValueError('Unsupported sound license or codec')
    at,start,length = (request[k] for k in ('timelineStartFrame','sourceStartFrame','durationFrames'))
    gain = request['gainDB']
    if not all(integer(x) for x in (at,start,length)) or length==0 or max(at+length,start+length)>2**63-1 or request['frameDurationNumerator']!=1001 or request['frameDurationDenominator']!=24000 or type(gain) not in (float,int) or not math.isfinite(gain) or not -60<=gain<=12: raise ValueError('Invalid frame range/timebase or gain')
    source = Directory(library);root = Directory(project);output = None
    try:
        subset = source.read('asset-library.json')
        if not any(p['package_manifest_sha256']==sha(subset) for p in compatibility['packages']): raise ValueError('Unpinned package manifest')
        if not any(a['asset_id']==asset['id'] and a['sha256']==asset['sha256'] and a['file_path']==asset['relativePath'] for a in strict(subset)['assets']): raise ValueError('Package membership mismatch')
        audio = source.read(asset['relativePath'],asset['bytes'])
        if len(audio)!=asset['bytes'] or sha(audio)!=asset['sha256']: raise ValueError('Original audio hash mismatch')
        with wave.open(io.BytesIO(audio),'rb') as wav:
            if wav.getframerate()!=asset['sampleRate'] or wav.getnchannels()!=asset['channels'] or len(wav.readframes(wav.getnframes()))!=wav.getnframes()*wav.getsampwidth()*wav.getnchannels(): raise ValueError('Audio decode mismatch')
            if Fraction(start+length)*Fraction(1001,24000)>Fraction(wav.getnframes(),wav.getframerate()): raise ValueError('Sound trim exceeds decoded samples')
        timeline_path = job['parentTimelineRelativePath'];values = parts(timeline_path)
        if len(values)!=4 or values[0]!='cuts' or values[2]!='exports' or not values[3].endswith('.fcpxml'): raise ValueError('Expected a saved cut timeline artifact')
        version_path = '/'.join(values[:2]+['clauto-version.json'])
        with lease(root):
            pinned = {p:root.read(p) for p in ('clauto-project.json','cuts/current.json',version_path,timeline_path)}
            manifest,version = strict(pinned['clauto-project.json']),strict(pinned[version_path])
            if manifest['id']!=job['projectID'] or version['id']!=job['parentVersionID'] or version['engineVersion']!=C.ENGINE_VERSION or manifest['engineVersion']!=C.ENGINE_VERSION or strict(pinned['cuts/current.json'])!=job['expectedCurrentID'] or sha(pinned[timeline_path])!=job['parentTimelineSHA256'] or sha(pinned[version_path])!=job['parentVersionSHA256'] or '/'.join(values[2:]) not in version['artifacts']: raise ValueError('Saved cut, engine, parent hash or current pointer changed')
            parent = root.child('build/derivatives',create=True)
            try:
                try: output = parent.child(job['id'])
                except FileNotFoundError: output = parent.child(job['id'],create=True)
                else:
                    receipt = strict(output.read('sound-timeline-adapter.json'))
                    if receipt['jobSHA256']!=sha(encode(job)): raise ValueError('Existing derivative is immutable')
                    for name,expected in receipt['outputSHA256'].items():
                        if sha(output.read(name,64*1024*1024))!=expected: raise ValueError('Existing derivative changed')
                    return receipt
            finally: parent.close()
        duration,primary,layers,chapters,dimensions = D.read_timeline(root.path/timeline_path,expected_sha=job['parentTimelineSHA256'])
        if Fraction(at+length)*Fraction(1001,24000)>Fraction(str(duration))+Fraction(1,10**8): raise ValueError('Sound ends beyond saved timeline')
        source_hashes = {str(p):D.sha(p) for p in {x.source for x in primary+layers}}
        output.write_new('source-asset.wav',audio)
        output.write_new('sound-reference.json',encode(ref));output.write_new('sound-job.json',encode(job))
        snapshot = output.path/'source-asset.wav'
        lane = min([C.LANE_FOLEY]+[x.lane for x in layers if x.audio_only])-1
        seconds = lambda frame:float(Fraction(frame)*Fraction(1001,24000))
        layers.append(D.Layer(snapshot,seconds(at),seconds(start),seconds(length),asset['title'],lane,'effects.foley',audio_only=True,gain_db=gain))
        aspect,resolution = manifest['aspect'],manifest.get('exportResolution','1080p')
        if tuple(C.canvas_spec(aspect,resolution)['author'])!=dimensions: raise ValueError('Saved canvas differs from project output settings')
        builder = FX.FCPXMLBuilder('Clauto sound selection — editable derivative',aspect,resolution=resolution)
        clips = [FX.Clip(x.source,x.at,x.start,x.duration,name=x.name,gain_db=x.gain_db,scale=x.scale,conform=x.conform,position=x.position,audio_enabled=not x.video_only) for x in primary]
        connected = [FX.Connected(x.source,x.at,x.duration,name=x.name,lane=x.lane,role=x.role,start=x.start,audio=x.audio_only,video_only=not x.audio_only,gain_db=x.gain_db if x.audio_only else None,scale=x.scale,position=x.position,conform=x.conform if not x.audio_only else None) for x in layers]
        tree = builder.build(clips,connected,chapters);ET.indent(tree,space='    ')
        xml = b'<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'+ET.tostring(tree.getroot(),encoding='utf-8')+b'\n'
        output.write_new('timeline.fcpxml',xml)
        problems = FX.validate(output.path/'timeline.fcpxml')
        if problems: raise ValueError('Timeline validation failed: '+'; '.join(problems))
        decoded = D.read_timeline(output.path/'timeline.fcpxml')
        selected = [x for x in decoded[2] if x.source==snapshot]
        # Validate the entire logical cue, including any future writer splitting.
        timeline_cursor,source_cursor = at,start
        for item in sorted(selected,key=lambda x:x.at):
            frames = C.frames(item.duration)
            if C.frames(item.at)!=timeline_cursor or C.frames(item.start)!=source_cursor or frames<=0 or item.gain_db!=gain or item.lane>=0 or not item.audio_only: raise ValueError('Inserted cue round-trip failed')
            timeline_cursor += frames;source_cursor += frames
        if not selected or timeline_cursor!=at+length or source_cursor!=start+length: raise ValueError('Inserted cue round-trip failed')
        before_publish()
        with lease(root):
            root.check();output.check();source.check()
            if any(root.read(p)!=data for p,data in pinned.items()) or any(D.sha(Path(p))!=h for p,h in source_hashes.items()) or sha(source.read(asset['relativePath'],asset['bytes']))!=asset['sha256']: raise ValueError('Inputs changed before publication; parent is preserved')
            names = ('source-asset.wav','sound-reference.json','sound-job.json','timeline.fcpxml')
            receipt = dict(schemaVersion=1,kind='editable_sound_timeline_derivative',jobSHA256=sha(encode(job)),projectID=job['projectID'],parentVersionID=job['parentVersionID'],parentTimelineSHA256=job['parentTimelineSHA256'],engineVersion=C.ENGINE_VERSION,request=request,outputSHA256={n:sha(output.read(n,64*1024*1024)) for n in names},sourceSHA256=source_hashes,structuralRoundTripPassed=True,schemaChecked=FX.dtd_problems(output.path/'timeline.fcpxml') is not None,previewRendered=False,admittedToEditorHistory=False,humanAudition='NOT_AUDITIONED')
            output.write_new('sound-timeline-adapter.json',encode(receipt));return receipt
    finally:
        if output: output.close()
        source.close();root.close()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project',required=True,type=Path);parser.add_argument('--library',required=True,type=Path);parser.add_argument('--job',required=True,type=Path)
    args = parser.parse_args()
    try:
        receipt = insert(args.project,args.library,strict(args.job.read_bytes()))
        print(json.dumps({'state':'complete','jobSHA256':receipt['jobSHA256'],'admittedToEditorHistory':False}));return 0
    except (Exception,KeyboardInterrupt) as error:
        print(json.dumps({'state':'stopped' if isinstance(error,KeyboardInterrupt) else 'failed','error':str(error),'parentPreserved':True}));return 1

if __name__=='__main__': raise SystemExit(main())
