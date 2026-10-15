"""Deterministic worker for native-issued synthetic source-span QA only.

This worker is not an approval authority. It never publishes a current pointer or
production cut. All writes use anchored directory descriptors and exclusive files.
Input descriptors pin inodes, not immutable bytes: in-place changes are checked
before/after; a general immutable-byte production transport remains future work.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import uuid
import wave
from fractions import Fraction
from xml.etree import ElementTree as ET

FPS_N, FPS_D, SAMPLE_RATE, SPF = 24000, 1001, 48000, 2002
GENERATOR = 'clauto-color-tone-v1'
ARTIFACTS = ('review.mov', 'timeline.fcpxml')
DTD = Path('/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_13.dtd')


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result: raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Non-finite JSON')))


def digest(data): return hashlib.sha256(data).hexdigest()
def identity(info): return {'device': info.st_dev, 'inode': info.st_ino}
def signature(info): return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
def leaf(name):
    if not name or name in ('.', '..') or '/' in name or '\0' in name: raise ValueError('Invalid owned filename')
    return name


class Directory:
    def __init__(self, path, expected=None, anchor=None):
        self.path = Path(path)
        self.anchor = anchor
        if not self.path.is_absolute() or '..' in self.path.parts: raise ValueError('Expected absolute owned path')
        # System aliases above the project (e.g. /var -> /private/var) are allowed;
        # every component *inside* its pinned root is opened without following links.
        if anchor is None:
            self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        else:
            parts = self.path.relative_to(anchor.path).parts
            self.fd = os.dup(anchor.fd)
            try:
                for part in parts:
                    next_fd = os.open(leaf(part), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
                    os.close(self.fd); self.fd = next_fd
            except BaseException:
                os.close(self.fd); self.fd = None; raise
        self.identity = identity(os.fstat(self.fd))
        if expected is not None and self.identity != expected:
            self.close(); raise ValueError('Workspace directory identity changed')
    def close(self):
        if self.fd is not None: os.close(self.fd); self.fd = None
    def __enter__(self): return self
    def __exit__(self, *args): self.close()
    def check(self):
        with Directory(self.path, self.identity, anchor=self.anchor): pass
    def create(self, name): return os.open(leaf(name), os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
    def open(self, name):
        fd = os.open(leaf(name), os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.fd)
        if not stat.S_ISREG(os.fstat(fd).st_mode): os.close(fd); raise ValueError('Expected a regular owned file')
        return fd
    def write(self, name, data):
        fd = self.create(name)
        try:
            with os.fdopen(os.dup(fd), 'wb') as stream: stream.write(data); stream.flush(); os.fsync(stream.fileno())
        finally: os.close(fd)
    def read(self, name, limit=64*1024*1024):
        fd = self.open(name)
        try:
            before = signature(os.fstat(fd))
            if before[2] > limit: raise ValueError('Owned input exceeds size limit')
            with os.fdopen(os.dup(fd), 'rb') as stream: data = stream.read(limit+1)
            if len(data) > limit: raise ValueError('Owned input grew beyond its size limit')
            current = self.open(name)
            try:
                if signature(os.fstat(fd)) != before or signature(os.fstat(current)) != before: raise ValueError('Owned input changed while being read')
            finally: os.close(current)
            return data
        finally: os.close(fd)


def hash_fd(fd):
    before = signature(os.fstat(fd)); os.lseek(fd, 0, os.SEEK_SET); sha = hashlib.sha256()
    while data := os.read(fd, 1024*1024): sha.update(data)
    os.lseek(fd, 0, os.SEEK_SET)
    if signature(os.fstat(fd)) != before: raise ValueError('Source changed during full byte verification')
    return sha.hexdigest()


def run(args, fds=()):
    for fd in fds: os.lseek(fd, 0, os.SEEK_SET)
    result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=tuple(fds))
    if result.returncode: raise ValueError('Local media tool failed: ' + result.stderr.decode(errors='replace')[-1800:])
    return result.stdout


def probe(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    return strict_json(run(['ffprobe','-v','error','-count_frames','-show_streams','-show_format','-of','json','-fd',str(fd),'fd:'], (fd,)))


def media_info(fd):
    data = probe(fd)
    videos = [s for s in data['streams'] if s['codec_type']=='video']
    audios = [s for s in data['streams'] if s['codec_type']=='audio']
    if len(videos)!=1 or len(audios)!=1: raise ValueError('Synthetic source requires one video and one audio stream')
    v, a = videos[0], audios[0]
    if Fraction(v['r_frame_rate']) != Fraction(FPS_N,FPS_D) or Fraction(v['avg_frame_rate']) != Fraction(FPS_N,FPS_D): raise ValueError('Unsupported source frame grid')
    if int(a['sample_rate']) != SAMPLE_RATE or int(a['channels']) != 1: raise ValueError('Unsupported source audio grid')
    if float(v.get('start_time','0')) != 0 or float(a.get('start_time','0')) != 0: raise ValueError('Synthetic streams must start at source zero')
    frames = int(v['nb_read_frames'])
    samples = int(Fraction(a['duration_ts']) * Fraction(a['time_base']) * SAMPLE_RATE)
    if samples != frames * SPF: raise ValueError('Video/audio source coverage is not exact; padding is not permitted')
    # Counts alone miss timestamp gaps introduced by container/concat rounding.
    packets=strict_json(run(['ffprobe','-v','error','-show_packets','-show_entries','packet=stream_index,pts,duration','-of','json','-fd',str(fd),'fd:'],(fd,)))['packets']
    cursors={v['index']:Fraction(0),a['index']:Fraction(0)}
    timebases={v['index']:Fraction(v['time_base']),a['index']:Fraction(a['time_base'])}
    video_packets=0
    for packet in packets:
        index=packet['stream_index']
        if index not in cursors: raise ValueError('Unexpected packet stream')
        at=int(packet['pts'])*timebases[index];duration=int(packet['duration'])*timebases[index]
        if at!=cursors[index] or duration<=0: raise ValueError('Packet coverage has a gap, overlap or retiming')
        if index==v['index']:
            if duration!=Fraction(FPS_D,FPS_N): raise ValueError('Video packet is off the source frame grid')
            video_packets+=1
        cursors[index]+=duration
    if video_packets!=frames or cursors[a['index']]!=Fraction(samples,SAMPLE_RATE): raise ValueError('Actual packets do not cover the exact planned frames/samples')
    return {'frames':frames,'samples':samples,'width':int(v['width']),'height':int(v['height'])}


def encode_json(data): return (json.dumps(data, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()
def emit(event): print(json.dumps(event), flush=True)
def seconds(frames): return str(Fraction(frames * FPS_D, FPS_N))
def fcp_time(frames):
    value=Fraction(frames * FPS_D,FPS_N)
    return f'{value.numerator}/{value.denominator}s' if value.denominator!=1 else f'{value.numerator}s'


def generated_wave(stage, name, frames, frequencies):
    fd=stage.create(name)
    try:
        with os.fdopen(os.dup(fd),'wb') as stream:
            with wave.open(stream,'wb') as wav:
                wav.setparams((1,2,SAMPLE_RATE,0,'NONE','not compressed'))
                import array
                values=array.array('h')
                for i in range(frames*SPF):
                    frequency=frequencies[0] if i<24*SPF else frequencies[-1]
                    values.append(round(5000*math.sin(2*math.pi*frequency*i/SAMPLE_RATE)))
                import sys
                if sys.byteorder!='little': values.byteswap()
                wav.writeframes(values.tobytes())
            stream.flush(); os.fsync(stream.fileno())
    finally: os.close(fd)


def generate(request, progress=emit):
    if request.get('schemaVersion')!=1 or request.get('generator')!=GENERATOR: raise ValueError('Unsupported synthetic generator')
    with Directory(request['projectPath'],request['projectIdentity']) as root, Directory(request['stagingPath'],request['stagingIdentity'],anchor=root) as stage:
        if stage.path != root.path/'synthetic-originals': raise ValueError('Generated sources must belong to the new QA project')
        for source_id, colors, frequencies in [('a',['red','blue'],[220,660]),('b',['0x20cc50'],[440])]:
            root.check();stage.check(); generated_wave(stage,source_id+'.wav',72,frequencies)
            audio=stage.open(source_id+'.wav');out=stage.create(source_id+'.mov')
            try:
                args=['ffmpeg','-hide_banner','-loglevel','error','-nostdin','-xerror','-err_detect','explode','-y']
                for index,color in enumerate(colors):
                    frames=24 if len(colors)==2 and index==0 else (48 if len(colors)==2 else 72)
                    args += ['-f','lavfi','-i',f'color=c={color}:s=160x90:r={FPS_N}/{FPS_D}:d={float(Fraction(frames*FPS_D,FPS_N)):.9f}']
                args += ['-fd',str(audio),'-i','fd:']
                if len(colors)==2: args += ['-filter_complex','[0:v][1:v]concat=n=2:v=1:a=0[v]','-map','[v]','-map','2:a']
                else: args += ['-map','0:v','-map','1:a']
                args += ['-frames:v','72','-c:v','libx264','-preset','ultrafast','-crf','0','-pix_fmt','yuv420p','-c:a','pcm_s16le','-f','mov','-movie_timescale','48000','-fd',str(out),'fd:']
                progress({'phase':'generating','sourceID':source_id});run(args,(audio,out));os.fsync(out)
            finally: os.close(audio);os.close(out)
            check=stage.open(source_id+'.mov')
            try:
                if media_info(check)['frames']!=72: raise ValueError('Synthetic generator returned wrong coverage')
            finally: os.close(check)
        root.check();stage.check()


def validate_input(request, manifest):
    if request.get('schemaVersion')!=1 or request.get('purpose')!='synthetic_source_span_acceptance' or request.get('productionAuthorized') is not False: raise ValueError('Production rendering is not authorized by this worker')
    if manifest.get('schemaVersion')!=1 or manifest.get('generator')!=GENERATOR or manifest['fixtureID']!=request['fixtureID']: raise ValueError('Wrong generated-fixture identity')
    m=request['map'];spans=request['spans']
    if manifest['projectID']!=m['projectID'] or m['reviewOnly'] is not True or m['appliedToCut'] is not False: raise ValueError('Invalid review-only source map')
    uuid.UUID(request['acknowledgementID'])
    if len(request['acknowledgementSHA256'])!=64 or not spans or len(spans)!=len(m['spans']): raise ValueError('Missing bound acknowledgment or spans')
    sources={s['sourceID']:s for s in manifest['sources']}
    if len(sources)!=len(manifest['sources']): raise ValueError('Duplicate fixture source identity')
    at=0;seen=set()
    for raw,span in zip(m['spans'],spans):
        if raw['id'] in seen or raw['sourceID'] not in sources: raise ValueError('Duplicate/unknown stable row identity')
        seen.add(raw['id']); source=sources[raw['sourceID']]
        if any(span[k]!=raw[v] for k,v in [('id','id'),('sourceID','sourceID'),('sourceSHA256','sourceSHA256'),('requestedIn','sourceIn'),('requestedOut','sourceOut')]): raise ValueError('Rendered span differs from selected stable row')
        if raw['sourceSHA256']!=source['sourceSHA256'] or raw['transcriptSHA256']!=source['transcriptSHA256']: raise ValueError('Source lost generated-fixture binding')
        def grid(value,ceil):
            if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or value<0: raise ValueError('Non-finite/negative source boundary')
            frame=value*FPS_N/FPS_D;nearest=round(frame)
            return nearest if abs(frame-nearest)<=1e-7 else (math.ceil(frame) if ceil else math.floor(frame))
        start,end=grid(raw['sourceIn'],False),grid(raw['sourceOut'],True)
        if any(isinstance(span[k],bool) or not isinstance(span[k],int) for k in ['startFrame','endFrame','startSample','endSample','timelineFrame']): raise ValueError('Frame/sample boundaries must be integers')
        if start<0 or end<=start or end>source['frames'] or (span['startFrame'],span['endFrame'],span['startSample'],span['endSample'],span['timelineFrame'])!=(start,end,start*SPF,end*SPF,at): raise ValueError('Unsupported frame rounding or uncovered source span')
        at+=end-start
    return sources,at


def timeline(request, source_info, sources):
    m=request['map'];root=ET.Element('fcpxml',version='1.13');resources=ET.SubElement(root,'resources')
    first=next(iter(source_info.values()))
    ET.SubElement(resources,'format',id='rFormat',frameDuration=fcp_time(1),width=str(first['width']),height=str(first['height']),colorSpace='1-1-1 (Rec. 709)')
    refs={}
    for i,(sid,source) in enumerate(sources.items()):
        ref=f'rAsset{i}';refs[sid]=ref;info=source_info[sid]
        asset=ET.SubElement(resources,'asset',id=ref,name=sid,start='0s',duration=fcp_time(info['frames']),hasVideo='1',hasAudio='1',format='rFormat',audioSources='1',audioChannels='1',audioRate=str(SAMPLE_RATE))
        ET.SubElement(asset,'media-rep',kind='original-media',src=(Path(request['projectPath'])/source['mediaRelativePath']).as_uri())
    library=ET.SubElement(root,'library');event=ET.SubElement(library,'event',name='Synthetic source-span QA')
    project=ET.SubElement(event,'project',name='Synthetic source review')
    total=sum(s['endFrame']-s['startFrame'] for s in request['spans'])
    sequence=ET.SubElement(project,'sequence',format='rFormat',duration=fcp_time(total),tcStart='0s',tcFormat='NDF',audioLayout='mono',audioRate='48k')
    spine=ET.SubElement(sequence,'spine')
    for span in request['spans']:
        ET.SubElement(spine,'asset-clip',name=span['id'],ref=refs[span['sourceID']],offset=fcp_time(span['timelineFrame']),start=fcp_time(span['startFrame']),duration=fcp_time(span['endFrame']-span['startFrame']),audioRole='dialogue')
    return b'<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'+ET.tostring(root,encoding='utf-8')


def render(request, input_sha, progress=emit):
    opened={};source_signatures={}
    with Directory(request['projectPath'],request['projectIdentity']) as root, Directory(request['stagingPath'],request['stagingIdentity'],anchor=root) as stage:
        if stage.path.parent!=root.path/'build'/'source-span-reviews' or not stage.path.name.startswith('.pending-'): raise ValueError('Wrong synthetic staging namespace')
        manifest_path=Path(request['fixtureManifestPath'])
        if manifest_path!=root.path/'.clauto'/'source-span-synthetic-fixture.json': raise ValueError('Wrong fixture manifest location')
        with Directory(root.path/'.clauto',anchor=root) as metadata, Directory(root.path/'synthetic-originals',anchor=root) as originals:
            manifest_bytes=metadata.read(manifest_path.name)
            if digest(manifest_bytes)!=request['fixtureManifestSHA256']: raise ValueError('Generated fixture manifest bytes changed')
            manifest=strict_json(manifest_bytes);sources,total=validate_input(request,manifest)
            map_bytes=stage.read('source-map.json')
            if digest(map_bytes)!=request['mapSHA256'] or strict_json(map_bytes)!=request['map']: raise ValueError('Frozen native source-map bytes changed')
            catalog_bytes=originals.read('catalog.json')
            if manifest['catalogRelativePath']!='synthetic-originals/catalog.json' or digest(catalog_bytes)!=manifest['catalogSHA256'] or digest(catalog_bytes)!=request['map']['catalogSHA256']: raise ValueError('Wrong exact generated catalog')
            catalog=strict_json(catalog_bytes)
            catalog_sources={s['source_id']:s for s in catalog['sources']}
            rows={r['id']:r for r in catalog['rows']}
            if len(rows)!=len(catalog['rows']): raise ValueError('Duplicate catalog row identity')
            for span in request['map']['spans']:
                row=rows.get(span['id'])
                if row is None or any(span[k]!=row[v] for k,v in [('sourceID','source_id'),('sourceSHA256','source_sha256'),('firstWord','first_word'),('lastWord','last_word'),('sourceIn','start'),('sourceOut','end')]): raise ValueError('Selected stable row does not map to its original words/times')
                src=catalog_sources[row['source_id']]
                if span['sourcePath']!=src['path'] or span['transcriptSHA256']!=src['transcript_sha256']: raise ValueError('Selected stable row source path changed')
                words=src['words'][row['first_word']:row['last_word']+1]
                if not words or any(w['start']<span['sourceIn'] or w['end']>span['sourceOut'] for w in words): raise ValueError('Selected word crosses its source span')
            if set(catalog_sources)!=set(sources) or len(catalog_sources)!=len(catalog['sources']): raise ValueError('Extra or duplicate catalog sources')
            info={}
            try:
                for sid,source in sources.items():
                    if source['mediaRelativePath']!=f'synthetic-originals/{sid}.mov' or source['transcriptRelativePath']!=f'synthetic-originals/{sid}.words.json': raise ValueError('Unsupported generated source path')
                    cat=catalog_sources[sid]
                    if cat['path']!=str(root.path/source['mediaRelativePath']) or cat['original_transcript']!=str(root.path/source['transcriptRelativePath']) or cat['source_sha256']!=source['sourceSHA256'] or cat['transcript_sha256']!=source['transcriptSHA256']: raise ValueError('Catalog source differs from generated manifest')
                    snapshot=originals.read(sid+'.words.json')
                    if digest(snapshot)!=source['transcriptSHA256'] or strict_json(snapshot)['words']!=cat['words']: raise ValueError('Original transcript changed')
                    fd=originals.open(sid+'.mov');opened[sid]=fd;source_signatures[sid]=signature(os.fstat(fd))
                    if hash_fd(fd)!=source['sourceSHA256']: raise ValueError('Original source bytes changed')
                    info[sid]=media_info(fd)
                    if info[sid]['frames']!=source['frames']: raise ValueError('Source coverage differs from fixture')
                if len({(s['width'],s['height']) for s in info.values()})!=1: raise ValueError('Mixed source dimensions are not supported in this increment')
                for index,span in enumerate(request['spans']):
                    root.check();stage.check();out=stage.create(f'part-{index:05d}.mov');src=opened[span['sourceID']]
                    try:
                        progress({'phase':'before_encode','id':span['id']})
                        run(['ffmpeg','-hide_banner','-loglevel','error','-nostdin','-xerror','-err_detect','explode','-y','-protocol_whitelist','fd','-fd',str(src),'-i','fd:',
                             '-vf',f"trim=start_frame={span['startFrame']}:end_frame={span['endFrame']},setpts=PTS-STARTPTS",
                             '-af',f"atrim=start_sample={span['startSample']}:end_sample={span['endSample']},asetpts=PTS-STARTPTS",
                             '-map','0:v:0','-map','0:a:0','-c:v','prores_ks','-profile:v','1','-pix_fmt','yuv422p10le','-c:a','pcm_s16le','-f','mov','-movie_timescale','48000','-fd',str(out),'fd:'],(src,out))
                        os.fsync(out)
                    finally: os.close(out)
                    part=stage.open(f'part-{index:05d}.mov')
                    try:
                        part_info=media_info(part)
                        if part_info['frames']!=span['endFrame']-span['startFrame']: raise ValueError('Encoded span frame/sample count differs from selection')
                    finally: os.close(part)
                    progress({'phase':'span_rendered','id':span['id']})
                parts=[stage.open(f'part-{i:05d}.mov') for i in range(len(request['spans']))]
                try:
                    stage.write('concat.txt', ''.join(f"file 'fd:'\noption fd {fd}\n" for fd in parts).encode())
                    concat=stage.open('concat.txt');out=stage.create('review.mov')
                    try: run(['ffmpeg','-hide_banner','-loglevel','error','-nostdin','-xerror','-err_detect','explode','-y','-f','concat','-safe','0','-protocol_whitelist','fd','-fd',str(concat),'-i','fd:','-map','0:v:0','-map','0:a:0','-c','copy','-f','mov','-movie_timescale','48000','-fd',str(out),'fd:'],(*parts,concat,out));os.fsync(out)
                    finally: os.close(concat);os.close(out)
                finally:
                    for fd in parts: os.close(fd)
                final=stage.open('review.mov')
                try:
                    final_info=media_info(final)
                    if final_info['frames']!=total or final_info['samples']!=total*SPF: raise ValueError('Final assembly coverage differs from ordered spans')
                    run(['ffmpeg','-hide_banner','-loglevel','error','-nostdin','-xerror','-err_detect','explode','-protocol_whitelist','fd','-fd',str(final),'-i','fd:','-map','0:v:0','-map','0:a:0','-f','null','-'],(final,))
                finally: os.close(final)
                xml=timeline(request,info,sources);stage.write('timeline.fcpxml',xml)
                checked=False
                if DTD.is_file():
                    from lxml import etree
                    with DTD.open('rb') as stream: schema=etree.DTD(stream)
                    if not schema.validate(etree.fromstring(xml,parser=etree.XMLParser(resolve_entities=False,no_network=True))): raise ValueError('Installed FCPXML schema rejected synthetic timeline')
                    checked=True
                for sid,fd in opened.items():
                    if signature(os.fstat(fd))!=source_signatures[sid] or hash_fd(fd)!=sources[sid]['sourceSHA256']: raise ValueError('Original source changed during rendering')
                    path=originals.open(sid+'.mov')
                    try:
                        if signature(os.fstat(path))!=source_signatures[sid]: raise ValueError('Original source path was replaced during rendering')
                    finally: os.close(path)
                root.check();stage.check();originals.check();metadata.check()
                hashes={}
                for name in ARTIFACTS:
                    fd=stage.open(name)
                    try: hashes[name]=hash_fd(fd)
                    finally: os.close(fd)
                # Native validates the exact map bytes separately; this is the native supplied immutable hash.
                receipt={'schemaVersion':1,'purpose':'synthetic_source_span_acceptance','productionAuthorized':False,
                    'inputSHA256':input_sha,'fixtureID':request['fixtureID'],'mapSHA256':request['mapSHA256'],
                    'acknowledgementID':request['acknowledgementID'],'acknowledgementSHA256':request['acknowledgementSHA256'],
                    'spans':request['spans'],'totalFrames':total,'audioSamples':total*SPF,'fullDecodePassed':True,'schemaChecked':checked,'artifactsSHA256':hashes}
                stage.write('render-proof.json',encode_json(receipt));progress({'phase':'worker_complete','frames':total})
                return receipt
            finally:
                for fd in opened.values(): os.close(fd)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True);mode.add_argument('--generate-fixture',type=Path);mode.add_argument('--render-synthetic',type=Path)
    parser.add_argument('--input-sha256',required=True)
    parser.add_argument('--input-directory-device',required=True,type=int)
    parser.add_argument('--input-directory-inode',required=True,type=int)
    args=parser.parse_args();path=args.generate_fixture or args.render_synthetic
    with Directory(path.parent,{'device':args.input_directory_device,'inode':args.input_directory_inode}) as owned_input:
        data=owned_input.read(path.name)
        owned_input.check()
    if digest(data)!=args.input_sha256: raise ValueError('Frozen worker input bytes changed')
    request=strict_json(data)
    if args.generate_fixture: generate(request)
    else: render(request,args.input_sha256)

if __name__=='__main__':
    try: main()
    except Exception as error:
        print(json.dumps({'phase':'failed','detail':str(error)}),flush=True)
        raise SystemExit(2)
