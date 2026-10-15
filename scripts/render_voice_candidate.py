"""Explicit review-only cuts of an exactly bound watched master.

Separate from production/source-span rendering. Originals and parent native XML
are retained; the editable output references the watched movie. Snapshot bytes
are temporary on a pinned local filesystem; all persistent output remains in the
project. No speech interpretation or approval authority lives in this worker.
"""
from __future__ import annotations
import argparse, ctypes, fcntl, hashlib, json, math, os, stat, subprocess
from fractions import Fraction
from pathlib import Path
from xml.etree import ElementTree as ET
import render_transcript_spans as S

MODE = 'watched_master_review_candidate_v1'
MASTER_LIMIT = 1024**3
OUTPUT_LIMIT = 8 * 1024**3
PARTS_LIMIT = (OUTPUT_LIMIT - 64*1024**2)//3
ARTIFACTS = ('review.mov', 'timeline.fcpxml', 'parent.fcpxml', 'candidate-plan.json', 'candidate-approval.json', 'source-map.json')


def local_filesystem(fd):
    # Darwin sys/mount.h __DARWIN_STRUCT_STATFS64; use the explicit 64-bit ABI.
    class StatFS(ctypes.Structure):
        _fields_=[('bsize',ctypes.c_uint32),('iosize',ctypes.c_int32),('blocks',ctypes.c_uint64),('bfree',ctypes.c_uint64),('bavail',ctypes.c_uint64),('files',ctypes.c_uint64),('ffree',ctypes.c_uint64),('fsid',ctypes.c_int32*2),('owner',ctypes.c_uint32),('type',ctypes.c_uint32),('flags',ctypes.c_uint32),('subtype',ctypes.c_uint32),('fstype',ctypes.c_char*16),('mnton',ctypes.c_char*1024),('mntfrom',ctypes.c_char*1024),('flags_ext',ctypes.c_uint32),('reserved',ctypes.c_uint32*7)]
    info=StatFS();libc=ctypes.CDLL(None,use_errno=True)
    if libc.fstatfs64(fd,ctypes.byref(info))!=0:raise OSError(ctypes.get_errno(),'Cannot inspect snapshot filesystem')
    return bool(info.flags & 0x1000) and bytes(info.fstype).split(b'\0')[0]==b'apfs'


def derive(plan):
    if plan.get('schemaVersion') != 1 or plan.get('mode') != MODE or plan.get('productionAuthorized') is not False or plan.get('issues'):
        raise ValueError('An explicit resolved review-candidate plan is required')
    total = plan['parentFrames']; operations = plan['operations']
    if type(total) is not int or not 0 < total <= 86400 or not 0 < len(operations) <= 64:
        raise ValueError('Review duration/range budget exceeded')
    removals=[]; protections=[]; ids=set()
    for op in operations:
        a,b=op['startFrame'],op['endFrame']
        if op['noteID'] in ids or type(a) is not int or type(b) is not int or not 0 <= a < b <= total:
            raise ValueError('Duplicate or invalid explicit note range')
        ids.add(op['noteID'])
        if op['action'] == 'remove': removals.append((a,b))
        elif op['action'] == 'protect': protections.append((a,b))
        else: raise ValueError('Unresolved edit action')
    if not removals or any(max(a,c)<min(b,d) for a,b in removals for c,d in protections):
        raise ValueError('No removal or a conflict with protected frames')
    union=[]
    for a,b in sorted(removals):
        if union and a <= union[-1][1]: union[-1]=(union[-1][0],max(b,union[-1][1]))
        else: union.append((a,b))
    fragments=[]; cursor=at=0
    for a,b in union+[(total,total)]:
        if a>cursor:
            fragments.append({'id':f'master-{cursor}-{a}','masterSHA256':plan['parent']['preview']['sha256'],
                'parentStartFrame':cursor,'parentEndFrame':a,'candidateStartFrame':at})
            at+=a-cursor
        cursor=max(cursor,b)
    if not fragments or len(fragments)>32 or fragments != plan['fragments']:
        raise ValueError('Candidate fragments do not exactly follow the reviewed parent-coordinate operations')
    return fragments,at


class MasterBudget:
    def __init__(self): self.used=0
    def reserve(self,size):
        if self.used or not 0<size<=MASTER_LIMIT: raise ValueError('Single watched-master byte quota exceeded')
        self.used=size


def digest_stream(args,fds,lease):
    for fd in fds: os.lseek(fd,0,os.SEEK_SET)
    process=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,pass_fds=tuple(fds)+(lease,))
    count=0; sha=hashlib.sha256()
    try:
        while block:=process.stdout.read(1024*1024): sha.update(block);count+=len(block)
        if process.wait(): raise ValueError('Decoded media verification failed')
        return sha.hexdigest(),count
    finally:
        process.stdout.close()
        if process.poll() is None: process.kill();process.wait()


def decoded(fd,kind,start,end,lease):
    filt=(f'trim=start_frame={start}:end_frame={end},setpts=PTS-STARTPTS,format=yuv420p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709' if kind=='video'
          else f'atrim=start_sample={start*S.SPF}:end_sample={end*S.SPF},asetpts=PTS-STARTPTS')
    args=['ffmpeg','-v','error','-nostdin','-xerror','-err_detect','explode','-protocol_whitelist','fd','-fd',str(fd),'-i','fd:','-map','0:v:0' if kind=='video' else '0:a:0']
    args+=['-vf',filt,'-pix_fmt','yuv420p','-f','rawvideo','-'] if kind=='video' else ['-af',filt,'-acodec','pcm_s16le','-f','s16le','-']
    return digest_stream(args,(fd,),lease)


def check_coverage(fd,plan,lease):
    data=S.strict_json(S.run(['ffprobe','-v','error','-show_streams','-show_format','-of','json','-fd',str(fd),'fd:'],(fd,lease)))
    vs=[s for s in data['streams'] if s['codec_type']=='video']; aud=[s for s in data['streams'] if s['codec_type']=='audio']
    if len(vs)!=1 or len(aud)!=1 or len(data['streams'])!=2: raise ValueError('One video and one audio stream are required')
    v,a=vs[0],aud[0]
    if Fraction(v['r_frame_rate'])!=Fraction(24000,1001) or Fraction(v['avg_frame_rate'])!=Fraction(24000,1001): raise ValueError('Unsupported watched-master frame grid')
    if int(a['sample_rate'])!=48000 or int(a['channels']) not in (1,2) or float(v.get('start_time',999))!=0 or float(a.get('start_time',999))!=0:
        raise ValueError('Unsupported sample rate, layout or stream offset; no padding/resampling is allowed')
    if v.get('pix_fmt')!='yuv420p' or v.get('sample_aspect_ratio','1:1')!='1:1' or v.get('color_space')!='bt709' or v.get('color_primaries')!='bt709' or v.get('color_transfer')!='bt709' or v.get('color_range')!='tv' or v.get('side_data_list'):
        raise ValueError('Only unrotated square-pixel 8-bit Rec.709 SDR masters are supported')
    if Fraction(v['duration_ts'])*Fraction(v['time_base'])!=Fraction(plan['parentFrames']*1001,24000):raise ValueError('Video metadata duration differs from its frozen frame count')
    if 'duration_ts' not in a or abs(float(Fraction(a['duration_ts'])*Fraction(a['time_base']))-plan['parentFrames']*1001/24000)>0.1:raise ValueError('Unsupported audio/video end coverage')
    width,height=int(v['width']),int(v['height'])
    if not 0<width<=3840 or not 0<height<=2160 or width%2 or height%2: raise ValueError('Unsupported frame dimensions')
    # Presentation timestamps, rather than reordered H264 packets, define coverage.
    frames=S.strict_json(S.run(['ffprobe','-v','error','-select_streams','v:0','-show_frames','-show_entries','frame=best_effort_timestamp','-of','json','-fd',str(fd),'fd:'],(fd,lease)))['frames']
    tb=Fraction(v['time_base'])
    if len(frames)!=plan['parentFrames'] or any(Fraction(f['best_effort_timestamp'])*tb != Fraction(i*1001,24000) for i,f in enumerate(frames)):
        raise ValueError('Decoded presentation frames have gaps, overlaps or retiming')
    audio_frames=S.strict_json(S.run(['ffprobe','-v','error','-select_streams','a:0','-show_frames','-show_entries','frame=best_effort_timestamp,nb_samples','-of','json','-fd',str(fd),'fd:'],(fd,lease)))['frames']
    audio_tb=Fraction(a['time_base']);cursor=0
    for frame in audio_frames:
        at=Fraction(frame['best_effort_timestamp'])*audio_tb*48000; samples=frame['nb_samples']
        if type(samples) is not int or samples<=0 or at!=cursor:raise ValueError('Decoded audio has a timestamp gap or overlap; no clock repair is permitted')
        cursor+=samples
    if cursor<plan['parentFrames']*S.SPF:raise ValueError('Decoded audio does not cover all retained movie frames')
    return width,height,int(a['channels'])


def timeline(plan,frames,width,height,channels,master_uri):
    root=ET.Element('fcpxml',version='1.13');r=ET.SubElement(root,'resources')
    ET.SubElement(r,'format',id='rFormat',frameDuration=S.fcp_time(1),width=str(width),height=str(height),colorSpace='1-1-1 (Rec. 709)')
    asset=ET.SubElement(r,'asset',id='rMaster',name='Exact watched master — review candidate',start='0s',duration=S.fcp_time(plan['parentFrames']),hasVideo='1',hasAudio='1',format='rFormat',audioSources='1',audioChannels=str(channels),audioRate='48000')
    ET.SubElement(asset,'media-rep',kind='original-media',src=master_uri)
    library=ET.SubElement(root,'library');event=ET.SubElement(library,'event',name='Review candidates')
    project=ET.SubElement(event,'project',name='Watched-master review candidate')
    sequence=ET.SubElement(project,'sequence',format='rFormat',duration=S.fcp_time(frames),tcStart='0s',tcFormat='NDF',audioLayout='mono' if channels==1 else 'stereo',audioRate='48k')
    spine=ET.SubElement(sequence,'spine')
    for f in plan['fragments']:
        ET.SubElement(spine,'asset-clip',name=f['id'],ref='rMaster',offset=S.fcp_time(f['candidateStartFrame']),start=S.fcp_time(f['parentStartFrame']),duration=S.fcp_time(f['parentEndFrame']-f['parentStartFrame']),audioRole='dialogue')
    return b'<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'+ET.tostring(root,encoding='utf-8')


def render(request,input_sha,progress=S.emit,*,wait_for_quota=True):
    if request.get('mode')!=MODE or request.get('productionAuthorized') is not False: raise ValueError('Wrong candidate capability')
    with S.Directory(request['projectPath'],request['projectIdentity']) as root, S.Directory(request['stagingPath'],request['stagingIdentity'],anchor=root) as stage, S.Directory(request['snapshotPath'],request['snapshotIdentity']) as local:
        if stage.path.parent != root.path/'build'/'voice-candidates' or not stage.path.name.startswith('.pending-'): raise ValueError('Wrong candidate output namespace')
        info=os.fstat(local.fd)
        if info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o700 or not local_filesystem(local.fd): raise ValueError('Snapshots require a pinned private local filesystem directory')
        with S.Directory('/private/tmp') as lease_parent:
            lease=os.open('clauto-voice-master-render-'+str(os.getuid())+'.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600,dir_fd=lease_parent.fd)
        try:
            li=os.fstat(lease)
            if not stat.S_ISREG(li.st_mode) or li.st_uid!=os.getuid() or li.st_nlink!=1: raise ValueError('Invalid global byte-quota lease')
            progress({"phase":"waiting_for_render_slot"})
            fcntl.flock(lease,fcntl.LOCK_EX | (0 if wait_for_quota else fcntl.LOCK_NB))
            lease_path=Path('/private/tmp')/('clauto-voice-master-render-'+str(os.getuid())+'.lock')
            if S.identity(os.stat(lease_path,follow_symlinks=False))!=S.identity(os.fstat(lease)) or os.fstat(lease).st_nlink!=1:raise ValueError('Global byte-quota lease path changed')
            plan_bytes=stage.read('candidate-plan.json');approval_bytes=stage.read('candidate-approval.json')
            plan=S.strict_json(plan_bytes);approval=S.strict_json(approval_bytes)
            fragments,total=derive(plan)
            if S.digest(plan_bytes)!=request['planSHA256'] or S.digest(approval_bytes)!=request['approvalSHA256'] or approval['planSHA256']!=request['planSHA256'] or approval['planID']!=plan['id'] or approval['scope']!=MODE or approval['productionAuthorized'] is not False: raise ValueError('Plan approval binding changed')
            parent_xml=stage.read('parent.fcpxml',limit=16*1024*1024)
            if S.digest(parent_xml)!=plan['parent']['timeline']['sha256']: raise ValueError('Parent native timeline changed')
            rel=Path(plan['parent']['preview']['relativePath'])
            if rel.is_absolute() or '..' in rel.parts: raise ValueError('Master must be inside its verified project')
            with S.Directory(root.path/rel.parent,anchor=root) as original_dir:
                fd=original_dir.open(rel.name);before=S.signature(os.fstat(fd))
                try:
                    def snapshot_progress(event):
                        if event['phase']!='source_snapshot_chunk' or event['bytes']%(16*1024*1024)==0:progress(event)
                    master=S.ReadonlySourceSnapshot.capture(fd,plan['parent']['preview']['sha256'],local,MasterBudget(),'watched-master',snapshot_progress)
                    try:
                        local.check();width,height,channels=check_coverage(master.fd,plan,lease)
                        checks=[];part_bytes=0
                        for i,f in enumerate(fragments):
                            progress({'phase':'render_fragment','index':i,'count':len(fragments)})
                            root.check();stage.check();local.check();out=stage.create(f'part-{i:03d}.mov')
                            try:
                                S.run(['ffmpeg','-v','error','-nostdin','-xerror','-err_detect','explode','-y','-threads','4','-protocol_whitelist','fd','-fd',str(master.fd),'-i','fd:',
                                    '-vf',f"trim=start_frame={f['parentStartFrame']}:end_frame={f['parentEndFrame']},setpts=PTS-STARTPTS,format=yuv420p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                                    '-af',f"atrim=start_sample={f['parentStartFrame']*S.SPF}:end_sample={f['parentEndFrame']*S.SPF},asetpts=PTS-STARTPTS",
                                    '-map','0:v:0','-map','0:a:0','-c:v','libx264','-preset','fast','-crf','0','-threads','4','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv','-c:a','pcm_s16le','-fs',str(PARTS_LIMIT-part_bytes),'-f','mov','-movie_timescale','48000','-fd',str(out),'fd:'],(master.fd,out,lease));os.fsync(out)
                                part_bytes+=os.fstat(out).st_size
                                if part_bytes>=PARTS_LIMIT: raise ValueError('Candidate output space quota exceeded')
                            finally: os.close(out)
                            part=stage.open(f'part-{i:03d}.mov')
                            try:
                                values={}
                                for kind in ('video','audio'):
                                    expected=decoded(master.fd,kind,f['parentStartFrame'],f['parentEndFrame'],lease)
                                    actual=decoded(part,kind,0,f['parentEndFrame']-f['parentStartFrame'],lease)
                                    wanted=(f['parentEndFrame']-f['parentStartFrame'])*(width*height*3//2 if kind=='video' else S.SPF*channels*2)
                                    if expected!=actual or actual[1]!=wanted: raise ValueError('Actual decoded candidate fragment differs from selected master frames/samples')
                                    values[kind]={'sha256':actual[0],'bytes':actual[1]}
                                checks.append(values)
                            finally: os.close(part)
                        parts=[stage.open(f'part-{i:03d}.mov') for i in range(len(fragments))]
                        try:
                            stage.write('concat.txt',''.join(f"file 'fd:'\noption fd {fd}\n" for fd in parts).encode());concat=stage.open('concat.txt');out=stage.create('review.mov')
                            try: S.run(['ffmpeg','-v','error','-nostdin','-xerror','-y','-f','concat','-safe','0','-protocol_whitelist','fd','-fd',str(concat),'-i','fd:','-map','0:v:0','-map','0:a:0','-c','copy','-fs',str(PARTS_LIMIT),'-f','mov','-movie_timescale','48000','-fd',str(out),'fd:'],(*parts,concat,out,lease));os.fsync(out)
                            finally: os.close(concat);os.close(out)
                        finally:
                            for part in parts: os.close(part)
                        final=stage.open('review.mov')
                        try:
                            check_coverage(final,{'parentFrames':total},lease)
                            _,actual_audio_bytes=digest_stream(['ffmpeg','-v','error','-nostdin','-xerror','-protocol_whitelist','fd','-fd',str(final),'-i','fd:','-map','0:a:0','-acodec','pcm_s16le','-f','s16le','-'],(final,),lease)
                            if actual_audio_bytes!=total*S.SPF*channels*2: raise ValueError('Final audio has missing or extra decoded samples')
                            for f,check in zip(fragments,checks):
                                for kind in ('video','audio'):
                                    actual=decoded(final,kind,f['candidateStartFrame'],f['candidateStartFrame']+f['parentEndFrame']-f['parentStartFrame'],lease)
                                    if actual!=(check[kind]['sha256'],check[kind]['bytes']): raise ValueError('Final assembled preview changed decoded frames/samples')
                            S.run(['ffmpeg','-v','error','-nostdin','-xerror','-protocol_whitelist','fd','-fd',str(final),'-i','fd:','-f','null','-'],(final,lease))
                        finally: os.close(final)
                        xml=timeline(plan,total,width,height,channels,(root.path/rel).as_uri())
                        schema_checked=False
                        if S.DTD.is_file():
                            from lxml import etree
                            with S.DTD.open('rb') as schema_file: schema=etree.DTD(schema_file)
                            if not schema.validate(etree.fromstring(xml,parser=etree.XMLParser(resolve_entities=False,no_network=True))): raise ValueError('Candidate FCPXML fails installed DTD')
                            schema_checked=True
                        stage.write('timeline.fcpxml',xml)
                        lineage={'mode':MODE,'parentVersionID':plan['parent']['versionID'],'parentNativeTimelineSHA256':S.digest(parent_xml),'masterSHA256':master.sha,'fragments':fragments,'nativeCameraAndGraphicsLineage':'verbatim parent.fcpxml; reference only, not independently edited or revalidated','canonicalVideo':'yuv420p8 decoded pixels','canonicalAudio':'48000 Hz signed 16-bit decoded PCM; no padding/resampling'}
                        stage.write('source-map.json',S.encode_json(lineage))
                        master.check();local.check();root.check();stage.check();original_dir.check()
                        current=original_dir.open(rel.name)
                        try:
                            if S.signature(os.fstat(fd))!=before or S.signature(os.fstat(current))!=before or S.hash_fd(fd)!=master.sha: raise ValueError('Watched master changed during rendering')
                        finally: os.close(current)
                        hashes={};sizes={}
                        for name in ARTIFACTS:
                            current=stage.open(name)
                            try: hashes[name]=S.hash_fd(current);sizes[name]=os.fstat(current).st_size
                            finally: os.close(current)
                        peak_bytes=part_bytes+2*sum(sizes.values())+64*1024**2
                        if sum(sizes.values())>PARTS_LIMIT or peak_bytes>OUTPUT_LIMIT: raise ValueError('Candidate publication peak space quota exceeded')
                        if S.identity(os.stat(lease_path,follow_symlinks=False))!=S.identity(os.fstat(lease)) or os.fstat(lease).st_nlink!=1:raise ValueError('Global byte-quota lease changed during rendering')
                        proof={'schemaVersion':1,'mode':MODE,'productionAuthorized':False,'appliedToWatchedVersion':False,'inputSHA256':input_sha,'planSHA256':request['planSHA256'],'approvalSHA256':request['approvalSHA256'],'masterSHA256':master.sha,'masterBytes':master.size,'readOnly':True,'unlinked':True,'snapshotIdentity':local.identity,'width':width,'height':height,'channels':channels,'peakNASBytesBudgeted':peak_bytes,'frames':total,'audioSamplesPerChannel':total*S.SPF,'fullDecodePassed':True,'schemaChecked':schema_checked,'fragments':fragments,'decodedFragments':checks,'artifactsSHA256':hashes,'artifactSizes':sizes}
                        proof_bytes=S.encode_json(proof);stage.write('render-proof.json',proof_bytes)
                        progress({'phase':'candidate_verified','frames':total,'renderProofSHA256':S.digest(proof_bytes)});return proof
                    finally: master.close()
                finally: os.close(fd)
        finally: os.close(lease)


def main():
    p=argparse.ArgumentParser();p.add_argument('input');p.add_argument('--input-sha256',required=True);args=p.parse_args()
    path=Path(args.input)
    with S.Directory(path.parent) as directory: data=directory.read(path.name)
    if S.digest(data)!=args.input_sha256: raise ValueError('Candidate request changed')
    request=S.strict_json(data)
    if path.parent!=Path(request['stagingPath']): raise ValueError('Wrong candidate input directory')
    render(request,args.input_sha256)

if __name__=='__main__': main()
