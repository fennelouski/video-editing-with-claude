"""Exact watched-master review candidates; generated color/tone media only."""
import copy
import json
import os
from pathlib import Path
import uuid
import pytest
import render_transcript_spans as S
import render_voice_candidate as V
from test_render_transcript_spans import fixture, render


def candidate_fixture(fixture,tmp_path,removals=((12,24),),protects=((0,12),)):
    root,parent,request=fixture
    render(fixture)
    stage=root/'build'/'voice-candidates'/('.pending-'+str(uuid.uuid4()));stage.mkdir(parents=True)
    local=tmp_path/'local-private-snapshot';local.mkdir(mode=0o700)
    master=parent/'watched-master.mov'
    S.run(['ffmpeg','-v','error','-nostdin','-i',str(parent/'review.mov'),'-vf','setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709','-c:v','libx264','-crf','0','-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-c:a','pcm_s16le',str(master)])
    parent_xml=(parent/'timeline.fcpxml').read_bytes()
    target={'versionID':str(uuid.uuid4()),'preview':{'sha256':S.digest(master.read_bytes()),'relativePath':str(master.relative_to(root))},'timeline':{'sha256':S.digest(parent_xml)}}
    ops=[{'noteID':str(uuid.uuid4()),'revision':1,'action':kind,'startFrame':a,'endFrame':b} for kind,ranges in [('remove',removals),('protect',protects)] for a,b in ranges]
    # Independent expected frozen-parent union in the test.
    kept=[i for i in range(36) if not any(a<=i<b for a,b in removals)]
    spans=[]
    for i in kept:
        if spans and spans[-1][1]==i:spans[-1]=(spans[-1][0],i+1)
        else:spans.append((i,i+1))
    fragments=[];at=0
    for a,b in spans:
        fragments.append({'id':f'master-{a}-{b}','masterSHA256':target['preview']['sha256'],'parentStartFrame':a,'parentEndFrame':b,'candidateStartFrame':at});at+=b-a
    plan={'schemaVersion':1,'id':str(uuid.uuid4()),'candidateID':str(uuid.uuid4()),'parent':target,'parentFrames':36,'operations':ops,'fragments':fragments,'issues':[],'mode':V.MODE,'productionAuthorized':False}
    plan_bytes=S.encode_json(plan);approval={'id':str(uuid.uuid4()),'planID':plan['id'],'planSHA256':S.digest(plan_bytes),'scope':V.MODE,'productionAuthorized':False}
    approval_bytes=S.encode_json(approval)
    (stage/'candidate-plan.json').write_bytes(plan_bytes);(stage/'candidate-approval.json').write_bytes(approval_bytes);(stage/'parent.fcpxml').write_bytes(parent_xml)
    job={'mode':V.MODE,'productionAuthorized':False,'projectPath':str(root),'projectIdentity':S.identity(root.stat()),'stagingPath':str(stage),'stagingIdentity':S.identity(stage.stat()),'snapshotPath':str(local),'snapshotIdentity':S.identity(local.stat()),'planSHA256':S.digest(plan_bytes),'approvalSHA256':S.digest(approval_bytes)}
    return stage,local,job,plan,master


def run_candidate(value,progress=lambda _:None):
    stage,local,job,plan,master=value
    data=S.encode_json(job);(stage/'input.json').write_bytes(data)
    return V.render(job,S.digest(data),progress)


@pytest.mark.parametrize('fault',['missing','changed','overlap','invalid'])
def test_inherited_protections_cannot_be_omitted_changed_or_removed(fault):
    protection={'noteID':str(uuid.uuid4()),'revision':1,'originTargetID':str(uuid.uuid4()),
                'originStartFrame':6,'originEndFrame':12,'startFrame':3,'endFrame':9}
    plan={'schemaVersion':1,'mode':V.MODE,'productionAuthorized':False,'issues':[],
          'parentFrames':24,'parent':{'preview':{'sha256':'a'*64},'candidateOrigin':{'protections':[protection]}},
          'inheritedProtections':[copy.deepcopy(protection)],
          'operations':[{'noteID':str(uuid.uuid4()),'action':'remove','startFrame':0,'endFrame':3}],
          'fragments':[{'id':'master-3-24','masterSHA256':'a'*64,'parentStartFrame':3,'parentEndFrame':24,'candidateStartFrame':0}]}
    assert V.derive(plan)[1]==21
    if fault=='missing':del plan['inheritedProtections']
    elif fault=='changed':plan['inheritedProtections'][0]['endFrame']=8
    elif fault=='overlap':plan['operations'][0].update(startFrame=4,endFrame=5)
    else:
        plan['inheritedProtections'][0]['startFrame']=False
        plan['parent']['candidateOrigin']['protections'][0]['startFrame']=False
    with pytest.raises(ValueError):V.derive(plan)


def test_remove_B_keeps_both_distinct_A_occurrences_and_exact_decoded_samples(fixture,tmp_path):
    value=candidate_fixture(fixture,tmp_path);stage,local,job,plan,master=value
    original=master.read_bytes();proof=run_candidate(value)
    assert proof['frames']==24 and proof['audioSamplesPerChannel']==48048
    assert proof['readOnly'] and proof['unlinked'] and not proof['productionAuthorized']
    assert [(f['parentStartFrame'],f['parentEndFrame'],f['candidateStartFrame']) for f in proof['fragments']]==[(0,12,0),(24,36,12)]
    def pcm(path):return S.run(['ffmpeg','-v','error','-nostdin','-i',str(path),'-map','0:a:0','-f','s16le','-'])
    parent=pcm(master);assert pcm(stage/'review.mov')==parent[:12*S.SPF*2]+parent[24*S.SPF*2:36*S.SPF*2]
    assert master.read_bytes()==original and not list(local.iterdir())
    assert (stage/'parent.fcpxml').read_bytes()==(master.parent/'timeline.fcpxml').read_bytes()
    assert json.loads((stage/'source-map.json').read_bytes())['fragments']==proof['fragments']


def test_middle_removal_splits_one_parent_occurrence_without_shifting_later_anchors(fixture,tmp_path):
    value=candidate_fixture(fixture,tmp_path,removals=((16,20),(18,22)),protects=((0,12),))
    proof=run_candidate(value)
    assert proof['frames']==30
    assert [(f['parentStartFrame'],f['parentEndFrame']) for f in proof['fragments']]==[(0,16),(22,36)]


@pytest.mark.parametrize('fault',['protect_conflict','missing_action','all_removed','wrong_fragments','wrong_approval','wrong_master','wrong_parent_xml','not_local_private','swapped_local_root','unsupported_zero_link'])
def test_candidate_refuses_unreviewed_changed_or_unsupported_capabilities(fixture,tmp_path,fault,monkeypatch):
    value=candidate_fixture(fixture,tmp_path);stage,local,job,plan,master=value
    if fault in ('protect_conflict','missing_action','all_removed','wrong_fragments'):
        if fault=='protect_conflict':plan['operations'][-1].update(startFrame=12,endFrame=15)
        elif fault=='missing_action':plan['operations'][0]['action']='guess'
        elif fault=='all_removed':plan['operations'][0].update(startFrame=0,endFrame=36)
        else:plan['fragments'][0]['parentStartFrame']=1
        data=S.encode_json(plan);(stage/'candidate-plan.json').write_bytes(data);job['planSHA256']=S.digest(data)
    elif fault=='wrong_approval':job['approvalSHA256']='0'*64
    elif fault=='wrong_master':master.write_bytes(b'altered master')
    elif fault=='wrong_parent_xml':(stage/'parent.fcpxml').write_bytes(b'<changed/>')
    elif fault=='not_local_private':local.chmod(0o755)
    elif fault=='swapped_local_root':local.rename(local.with_name('original-owned-local'));local.mkdir(mode=0o700)
    else:
        original_check=S.ReadonlySourceSnapshot.check
        def fail(self):raise ValueError('Filesystem cannot attest zero links')
        monkeypatch.setattr(S.ReadonlySourceSnapshot,'check',fail)
    with pytest.raises((ValueError,OSError,KeyError)):run_candidate(value)
    assert not (stage/'render-proof.json').exists()


def test_global_master_quota_lease_is_retained_by_subordinate_processes(fixture,tmp_path):
    value=candidate_fixture(fixture,tmp_path);stage,local,job,plan,master=value
    import fcntl
    fd=os.open('/private/tmp/clauto-voice-master-render-'+str(os.getuid())+'.lock',os.O_CREAT|os.O_RDWR,0o600)
    try:
        # Acquire the test owner normally: another legitimate native/Python render
        # may hold the same global lease. Only the contender must be nonblocking.
        fcntl.flock(fd,fcntl.LOCK_EX)
        with pytest.raises(BlockingIOError):V.render(job,'0'*64,lambda _:None,wait_for_quota=False)
    finally:os.close(fd)
    assert not (stage/'render-proof.json').exists()


def rebind_master(value,new_master):
    stage,local,job,plan,_=value
    plan['parent']['preview']={'sha256':S.digest(new_master.read_bytes()),'relativePath':str(new_master.relative_to(Path(job['projectPath'])))}
    for fragment in plan['fragments']:fragment['masterSHA256']=plan['parent']['preview']['sha256']
    data=S.encode_json(plan);(stage/'candidate-plan.json').write_bytes(data);job['planSHA256']=S.digest(data)
    approval=json.loads((stage/'candidate-approval.json').read_bytes());approval['planSHA256']=job['planSHA256']
    data=S.encode_json(approval);(stage/'candidate-approval.json').write_bytes(data);job['approvalSHA256']=S.digest(data)
    return stage,local,job,plan,new_master


def test_actual_B_frame_H264_AAC_stereo_master_uses_decoded_presentation_clock(fixture,tmp_path):
    value=candidate_fixture(fixture,tmp_path);master=value[-1];aac=master.with_name('watched-AAC.mp4')
    S.run(['ffmpeg','-v','error','-nostdin','-i',str(master),'-c:v','libx264','-bf','2','-crf','18','-pix_fmt','yuv420p','-c:a','aac','-ac','2',str(aac)])
    proof=run_candidate(rebind_master(value,aac))
    assert proof['channels']==2 and proof['frames']==24 and proof['audioSamplesPerChannel']==48048


@pytest.mark.parametrize('shift',[2002,-2002])
def test_decoded_audio_timestamp_gaps_and_overlaps_are_refused(fixture,tmp_path,monkeypatch,shift):
    # MOV can normalize PCM timestamps during muxing. Inject the decoded ffprobe
    # timestamp response so this tests the no-repair gate, not muxer behavior.
    value=candidate_fixture(fixture,tmp_path);original=S.run
    def altered(args,fds=()):
        result=original(args,fds)
        if args[0]=='ffprobe' and 'frame=best_effort_timestamp,nb_samples' in args:
            data=json.loads(result);data['frames'][1]['best_effort_timestamp']+=shift
            return S.encode_json(data)
        return result
    monkeypatch.setattr(S,'run',altered)
    with pytest.raises(ValueError,match='timestamp gap|cover|samples'):run_candidate(value)
    assert not (value[0]/'render-proof.json').exists()


def test_real_muxed_audio_shortfall_is_refused(fixture,tmp_path):
    value=candidate_fixture(fixture,tmp_path);master=value[-1];bad=master.with_name('audio-shortfall.mov')
    S.run(['ffmpeg','-v','error','-nostdin','-i',str(master),'-c:v','copy','-af','atrim=end_sample=70070','-c:a','pcm_s16le',str(bad)])
    with pytest.raises(ValueError,match='cover'):run_candidate(rebind_master(value,bad))


@pytest.mark.parametrize('field,value',[('pix_fmt','yuv420p10le'),('sample_aspect_ratio','2:1'),('color_primaries','bt2020'),('color_transfer','smpte2084'),('side_data_list',[{'rotation':90}]),('color_primaries',None),('color_transfer','unknown'),('color_space',None)])
def test_unsupported_display_transform_and_HDR_metadata_are_never_silently_converted(fixture,tmp_path,monkeypatch,field,value):
    candidate=candidate_fixture(fixture,tmp_path);original=S.run
    def altered(args,fds=()):
        result=original(args,fds)
        if args[0]=='ffprobe' and '-show_streams' in args:
            data=json.loads(result);video=next(s for s in data['streams'] if s['codec_type']=='video');video[field]=value
            return S.encode_json(data)
        return result
    monkeypatch.setattr(S,'run',altered)
    with pytest.raises(ValueError,match='8-bit Rec.709'):run_candidate(candidate)
    assert not (candidate[0]/'render-proof.json').exists()


def test_global_lease_remains_held_after_parent_closes_its_handle_until_child_exits(tmp_path):
    import fcntl,subprocess,sys
    path='/private/tmp/clauto-voice-master-render-'+str(os.getuid())+'.lock'
    owner=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600);contender=None;child=None
    try:
        fcntl.flock(owner,fcntl.LOCK_EX)
        child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(5)'],pass_fds=(owner,))
        os.close(owner);owner=None
        contender=os.open(path,os.O_RDWR|os.O_NOFOLLOW)
        with pytest.raises(BlockingIOError):fcntl.flock(contender,fcntl.LOCK_EX|fcntl.LOCK_NB)
        child.terminate();child.wait();child=None
        fcntl.flock(contender,fcntl.LOCK_EX|fcntl.LOCK_NB)
    finally:
        if child is not None:child.terminate();child.wait()
        if owner is not None:os.close(owner)
        if contender is not None:os.close(contender)
