"""Real local synthetic color/tone media; no footage, AI, app or current-cut access."""
import copy
import errno
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import shutil
import uuid
from fractions import Fraction
from xml.etree import ElementTree as ET

import pytest
import render_transcript_spans as R


def encode(value): return R.encode_json(value)


@pytest.fixture
def fixture(tmp_path):
    root=tmp_path.resolve()/'Synthetic QA'; root.mkdir(); (root/'.clauto').mkdir(); (root/'synthetic-originals').mkdir()
    (root/'build'/'source-span-reviews').mkdir(parents=True)
    stage=root/'build'/'source-span-reviews'/('.pending-'+str(uuid.uuid4()));stage.mkdir()
    project_id,fixture_id=str(uuid.uuid4()),str(uuid.uuid4())
    request={'schemaVersion':1,'generator':R.GENERATOR,'fixtureID':fixture_id,'projectPath':str(root),
        'projectIdentity':R.identity(root.stat()),'stagingPath':str(root/'synthetic-originals'),
        'stagingIdentity':R.identity((root/'synthetic-originals').stat())}
    R.generate(request,progress=lambda _:None)
    sources=[];rows=[];inventory=[]
    for sid,ranges in [('a',[(6,18),(42,54)]),('b',[(24,36)])]:
        media=root/'synthetic-originals'/f'{sid}.mov';sha=R.digest(media.read_bytes())
        words=[{'word':f'Synthetic {sid}{i}.','start':start*R.FPS_D/R.FPS_N,'end':end*R.FPS_D/R.FPS_N} for i,(start,end) in enumerate(ranges)]
        snapshot=encode({'words':words});ts=R.digest(snapshot);transcript=media.with_suffix('.words.json');transcript.write_bytes(snapshot)
        sources.append({'source_id':sid,'path':str(media),'source_sha256':sha,'transcript_sha256':ts,'duration_seconds':3.003,'words':words,'original_transcript':str(transcript)})
        inventory.append({'sourceID':sid,'mediaRelativePath':f'synthetic-originals/{sid}.mov','sourceSHA256':sha,
            'transcriptRelativePath':f'synthetic-originals/{sid}.words.json','transcriptSHA256':ts,'frames':72})
        for i,((start,end),word) in enumerate(zip(ranges,words)):
            rows.append({'id':f'{sid}-w{i:05d}-{i:05d}-{sha[:8]}','source_id':sid,'source_sha256':sha,'first_word':i,'last_word':i,'start':word['start'],'end':word['end'],'text':word['word']})
    catalog=encode({'sources':sources,'rows':rows});catalog_sha=R.digest(catalog)
    (root/'synthetic-originals'/'catalog.json').write_bytes(catalog)
    manifest={'schemaVersion':1,'generator':R.GENERATOR,'projectID':project_id,'fixtureID':fixture_id,'catalogRelativePath':'synthetic-originals/catalog.json','catalogSHA256':catalog_sha,'sources':inventory}
    manifest_bytes=encode(manifest);manifest_path=root/'.clauto'/'source-span-synthetic-fixture.json';manifest_path.write_bytes(manifest_bytes)
    mapped=[];rendered=[];at=0.0
    for index,row in enumerate([rows[0],rows[2],rows[1]]):
        source=next(s for s in sources if s['source_id']==row['source_id']);start,end=[6,24,42][index],[18,36,54][index]
        mapped.append({'id':row['id'],'sourceID':source['source_id'],'sourcePath':source['path'],'sourceSHA256':source['source_sha256'],
            'transcriptSHA256':source['transcript_sha256'],'firstWord':row['first_word'],'lastWord':row['last_word'],
            'sourceIn':row['start'],'sourceOut':row['end'],'selectionIn':at,'selectionOut':at+row['end']-row['start']})
        rendered.append({'id':row['id'],'sourceID':source['source_id'],'sourceSHA256':source['source_sha256'],
            'requestedIn':row['start'],'requestedOut':row['end'],'startFrame':start,'endFrame':end,'startSample':start*R.SPF,'endSample':end*R.SPF,'timelineFrame':index*12})
        at+=row['end']-row['start']
    mapping={'schemaVersion':1,'projectID':project_id,'reviewID':str(uuid.uuid4()),'revisionID':str(uuid.uuid4()),
        'catalogSHA256':catalog_sha,'revisionSHA256':'a'*64,'spans':mapped,'untrimmedSelectionSeconds':at,'reviewOnly':True,'appliedToCut':False}
    map_bytes=encode(mapping);(stage/'source-map.json').write_bytes(map_bytes)
    request={'schemaVersion':1,'purpose':'synthetic_source_span_acceptance','productionAuthorized':False,'projectPath':str(root),'projectIdentity':R.identity(root.stat()),
        'stagingPath':str(stage),'stagingIdentity':R.identity(stage.stat()),'fixtureID':fixture_id,'fixtureManifestPath':str(manifest_path),'fixtureManifestSHA256':R.digest(manifest_bytes),
        'map':mapping,'mapSHA256':R.digest(map_bytes),'acknowledgementID':str(uuid.uuid4()),'acknowledgementSHA256':'b'*64,'spans':rendered}
    return root,stage,request


def render(fixture,progress=lambda _:None):
    root,stage,request=fixture;data=encode(request);(stage/'input.json').write_bytes(data)
    return R.render(request,R.digest(data),progress=progress)


def test_decoded_output_has_exact_A_B_A_samples_frames_and_source_timeline(fixture):
    root,stage,request=fixture;before={p.name:R.digest(p.read_bytes()) for p in (root/'synthetic-originals').iterdir()}
    receipt=render(fixture)
    assert receipt['totalFrames']==36 and receipt['audioSamples']==72072 and receipt['fullDecodePassed']
    assert receipt['sourceByteStrategy']==R.SOURCE_BYTE_STRATEGY
    assert set(receipt['sourceBytes'])=={'a','b'}
    assert all(v['readOnly'] and v['unlinked'] and 0<v['byteCount']<=R.SOURCE_MAX_BYTES for v in receipt['sourceBytes'].values())
    assert not list(stage.glob('.source-snapshot-*'))
    def pcm(path): return R.run(['ffmpeg','-v','error','-nostdin','-i',str(path),'-map','0:a:0','-f','s16le','-'])
    originals={sid:pcm(root/'synthetic-originals'/f'{sid}.mov') for sid in ['a','b']}
    expected=b''.join(originals[s['sourceID']][s['startSample']*2:s['endSample']*2] for s in request['spans'])
    assert pcm(stage/'review.mov')==expected
    tree=ET.parse(stage/'timeline.fcpxml');clips=tree.findall('.//spine/asset-clip')
    assert [c.attrib['name'] for c in clips]==[s['id'] for s in request['spans']]
    assert [Fraction(c.attrib['start'][:-1]) for c in clips]==[Fraction(i*1001,24000) for i in [6,24,42]]
    assert before=={p.name:R.digest(p.read_bytes()) for p in (root/'synthetic-originals').iterdir()}


@pytest.mark.parametrize('fault',['row','range','nan','duplicates','production','map_bytes','manifest','extra_source','missing','changed'])
def test_changed_unbound_or_unsupported_inputs_refuse_success(fixture,fault):
    root,stage,request=fixture
    if fault=='row': request['spans'][0]['id']='unselected-row'
    elif fault=='range': request['spans'][0]['startFrame']=7
    elif fault=='nan': request['map']['spans'][0]['sourceIn']=float('nan')
    elif fault=='duplicates': request['map']['spans'][1]['id']=request['map']['spans'][0]['id']
    elif fault=='production': request['productionAuthorized']=True
    elif fault=='map_bytes': (stage/'source-map.json').write_bytes(b'{}')
    elif fault=='manifest': request['fixtureID']=str(uuid.uuid4())
    elif fault=='extra_source':
        manifest_path=Path(request['fixtureManifestPath']);manifest=R.strict_json(manifest_path.read_bytes());manifest['sources'].append(copy.deepcopy(manifest['sources'][0]))
        value=encode(manifest);manifest_path.write_bytes(value);request['fixtureManifestSHA256']=R.digest(value)
    elif fault=='missing': (root/'synthetic-originals'/'a.mov').unlink()
    elif fault=='changed': (root/'synthetic-originals'/'a.mov').write_bytes(b'changed source')
    with pytest.raises((ValueError,OSError)):
        if fault=='nan': R.render(request,'0'*64,progress=lambda _:None)
        else: render(fixture)
    assert not (stage/'render-proof.json').exists()


def test_destination_swap_during_encode_cannot_write_or_cleanup_replacement(fixture):
    root,stage,request=fixture;owned=stage.with_name('disconnected-owned-stage');ran=False
    def swap(event):
        nonlocal ran
        if event['phase']=='before_encode' and not ran:
            ran=True;stage.rename(owned);stage.mkdir();(stage/'sentinel').write_bytes(b'foreign replacement')
    with pytest.raises((ValueError,OSError)): render(fixture,progress=swap)
    assert ran and sorted(p.name for p in stage.iterdir())==['sentinel']
    # FFmpeg used an already-open descriptor into the original owned directory.
    assert (owned/'part-00000.mov').is_file() and (owned/'part-00000.mov').stat().st_size>0
    assert not (owned/'render-proof.json').exists()


def test_no_space_during_real_assembly_retains_parts_and_never_publishes(fixture,monkeypatch):
    root,stage,_=fixture;sentinel=root/'.clauto'/'source-span-synthetic-current.json';sentinel.write_bytes(b'previous current')
    create=R.Directory.create
    def fail(self,name):
        if name=='review.mov': raise OSError(errno.ENOSPC,'Simulated NAS full')
        return create(self,name)
    monkeypatch.setattr(R.Directory,'create',fail)
    with pytest.raises(OSError,match='Simulated NAS full'): render(fixture)
    assert (stage/'part-00000.mov').is_file() and not (stage/'render-proof.json').exists()
    assert sentinel.read_bytes()==b'previous current'


def test_source_in_place_mutation_during_encode_refuses_success(fixture):
    root,stage,_=fixture;ran=False
    def mutate(event):
        nonlocal ran
        if event['phase']=='before_encode' and not ran:
            ran=True
            path=root/'synthetic-originals'/'a.mov'
            with path.open('r+b') as stream: stream.seek(-1,os.SEEK_END);value=stream.read(1);stream.seek(-1,os.SEEK_END);stream.write(bytes([value[0]^1]))
    with pytest.raises((ValueError,OSError)): render(fixture,progress=mutate)
    assert ran and not (stage/'render-proof.json').exists()


@pytest.mark.parametrize('fault',['replace','truncate','restore'])
def test_concurrent_original_changes_cannot_change_validated_render_bytes(fixture,monkeypatch,fault):
    root,stage,request=fixture;path=root/'synthetic-originals'/'a.mov';original=path.read_bytes()
    prior=root/'.clauto'/'source-span-synthetic-current.json';prior.write_bytes(b'prior immutable current')
    checked=[];real_info=R.media_info;ran=False
    def inspect(fd):
        # Every source media validation receives an unlinked O_RDONLY inode.
        if os.fstat(fd).st_nlink==0:
            assert fcntl.fcntl(fd,fcntl.F_GETFL)&os.O_ACCMODE==os.O_RDONLY
            assert R.hash_fd(fd) in {s['sourceSHA256'] for s in request['spans']}
            with pytest.raises(OSError): os.write(fd,b'forbidden')
            with pytest.raises(OSError): os.ftruncate(fd,0)
            checked.append(fd)
        return real_info(fd)
    monkeypatch.setattr(R,'media_info',inspect)
    def progress(event):
        nonlocal ran
        if event['phase']=='before_encode' and not ran:
            ran=True
            def mutate():
                if fault=='replace':
                    replacement=path.with_suffix('.replacement');replacement.write_bytes(original);os.replace(replacement,path)
                else:
                    with path.open('r+b') as stream:
                        stream.truncate(0);stream.flush();os.fsync(stream.fileno())
                        if fault=='restore': stream.write(original);stream.flush();os.fsync(stream.fileno())
            with concurrent.futures.ThreadPoolExecutor() as pool: pool.submit(mutate).result(timeout=5)
    with pytest.raises((ValueError,OSError)): render(fixture,progress)
    assert ran and len(checked)==2 and not (stage/'render-proof.json').exists()
    # Even truncating the original before encoding cannot alter this retained part.
    assert (stage/'part-00000.mov').is_file()
    decoded=R.run(['ffmpeg','-v','error','-i',str(stage/'part-00000.mov'),'-map','0:a:0','-f','s16le','-'])
    restored=stage/'expected-original.mov';restored.write_bytes(original)
    expected=R.run(['ffmpeg','-v','error','-i',str(restored),'-map','0:a:0','-f','s16le','-'])
    assert decoded==expected[6*R.SPF*2:18*R.SPF*2]
    assert prior.read_bytes()==b'prior immutable current' and not list(stage.glob('.source-snapshot-*'))


@pytest.mark.parametrize('fault',['read_error','early_eof','growth','cancel','cancel_after_ready','snapshot_write_error','snapshot_short_write','unlink_error','reader_open_error','validation_read_error'])
def test_snapshot_capture_failures_close_handles_and_preserve_current(fixture,monkeypatch,fault):
    root,stage,_=fixture;prior=root/'.clauto'/'source-span-synthetic-current.json';prior.write_bytes(b'prior')
    original=root/'synthetic-originals'/'a.mov';inode=original.stat().st_ino
    real_read,real_write,real_open,real_create,real_unlink,real_info=R.os.read,R.os.write,R.Directory.open,R.Directory.create,R.os.unlink,R.media_info
    descriptors=[];copied=False
    def track_open(self,name):
        if fault=='reader_open_error' and name.startswith('.source-snapshot-'): raise OSError(errno.EIO,'Simulated snapshot open failure')
        fd=real_open(self,name)
        if name=='a.mov' or name.startswith('.source-snapshot-'): descriptors.append(fd)
        return fd
    def track_create(self,name):
        fd=real_create(self,name)
        if name.startswith('.source-snapshot-'): descriptors.append(fd)
        return fd
    def read(fd,size):
        if os.fstat(fd).st_ino==inode and fault=='read_error': raise OSError(errno.EIO,'Simulated NAS read failure')
        return real_read(fd,size)
    def write(fd,data):
        if os.fstat(fd).st_nlink==0:
            if fault=='snapshot_write_error': raise OSError(errno.ENOSPC,'Simulated private snapshot write failure')
            if fault=='snapshot_short_write': return 0
        return real_write(fd,data)
    def progress(event):
        nonlocal copied
        if fault=='cancel_after_ready' and event['phase']=='source_snapshot_ready': raise concurrent.futures.CancelledError('Synthetic ready cancelled')
        if event['phase']=='source_snapshot_chunk' and not copied:
            copied=True
            if fault=='early_eof':
                with original.open('r+b') as stream: stream.truncate(event['bytes'])
            if fault=='growth':
                with original.open('ab') as stream: stream.write(b'growth')
            if fault=='cancel': raise concurrent.futures.CancelledError('Synthetic capture cancelled')
    def unlink(name,**kw):
        if fault=='unlink_error' and str(name).startswith('.source-snapshot-'): raise OSError(errno.ENOTSUP,'Simulated unsupported unlink-open semantics')
        return real_unlink(name,**kw)
    def info(fd):
        if fault=='validation_read_error' and os.fstat(fd).st_nlink==0: raise OSError(errno.EIO,'Simulated private snapshot read failure')
        return real_info(fd)
    monkeypatch.setattr(R.Directory,'open',track_open);monkeypatch.setattr(R.Directory,'create',track_create)
    monkeypatch.setattr(R.os,'read',read);monkeypatch.setattr(R.os,'write',write)
    monkeypatch.setattr(R.os,'unlink',unlink);monkeypatch.setattr(R,'media_info',info)
    with pytest.raises((ValueError,OSError,concurrent.futures.CancelledError)): render(fixture,progress)
    assert prior.read_bytes()==b'prior' and not (stage/'render-proof.json').exists()
    remaining=list(stage.glob('.source-snapshot-*'))
    assert all(p.stat().st_size==0 for p in remaining)
    assert bool(remaining)==(fault in ['unlink_error','reader_open_error'])
    for fd in set(descriptors):
        with pytest.raises(OSError): os.fstat(fd)


def test_snapshot_limits_precede_copy_and_write_capability_is_not_retained(tmp_path):
    folder=tmp_path.resolve();source=folder/'source';source.write_bytes(b'x'*20)
    with R.Directory(folder) as stage:
        fd=stage.open('source')
        try:
            budget=R.SnapshotBudget();budget.used=R.JOB_MAX_BYTES-10
            with pytest.raises(ValueError,match='budget'): R.ReadonlySourceSnapshot.capture(fd,R.digest(source.read_bytes()),stage,budget,'a',lambda _:None)
            with source.open('r+b') as stream: stream.truncate(R.SOURCE_MAX_BYTES+1)
            with pytest.raises(ValueError,match='budget'): R.ReadonlySourceSnapshot.capture(fd,'0'*64,stage,R.SnapshotBudget(),'a',lambda _:None)
            assert not list(folder.glob('.source-snapshot-*'))
        finally: os.close(fd)


def test_two_concurrent_renders_use_independent_private_snapshot_descriptors(fixture):
    root,stage,request=fixture
    second=stage.with_name('.pending-'+str(uuid.uuid4()));second.mkdir();(second/'source-map.json').write_bytes((stage/'source-map.json').read_bytes())
    other=copy.deepcopy(request);other['stagingPath']=str(second);other['stagingIdentity']=R.identity(second.stat())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs=[pool.submit(render,fixture),pool.submit(render,(root,second,other))]
        proofs=[job.result(timeout=30) for job in jobs]
    assert proofs[0]['sourceBytes']==proofs[1]['sourceBytes']
    assert proofs[0]['artifactsSHA256']['review.mov']==proofs[1]['artifactsSHA256']['review.mov']
    assert not list(root.rglob('.source-snapshot-*'))
