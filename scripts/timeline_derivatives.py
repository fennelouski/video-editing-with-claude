"""Local, immutable derivatives of the supported Clauto asset-clip timeline.

Never opens Final Cut, contacts a model, or edits an original/saved parent. Unknown
timeline effects are refused rather than silently flattened incorrectly.
"""
from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass, asdict
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
from urllib.parse import urlparse, unquote
from xml.etree import ElementTree as ET
from xml.parsers import expat

import config as C
import fcpxml as FX
from duration_bounds import final_sequence_duration


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''): digest.update(block)
    return digest.hexdigest()


def seconds(text: str | None) -> float:
    if not isinstance(text, str) or not re.fullmatch(r'[0-9]+(?:/[0-9]+)?s', text):
        raise ValueError('Timeline times must be finite, nonnegative rational seconds.')
    value = float(Fraction(text[:-1]))
    if not math.isfinite(value): raise ValueError('Timeline time is not finite.')
    return value


def run(command: list[str], *, directory: Path | None = None) -> None:
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, cwd=directory)
    if result.returncode: raise RuntimeError(result.stderr.decode(errors='replace')[-1800:])


def measured_true_peak(stderr: str) -> tuple[float | None, bool]:
    values=re.findall(r'Peak:\s+([+-]?(?:[0-9]+(?:\.[0-9]+)?|inf))\s+dBFS',stderr)
    if not values: raise ValueError('The audio true-peak measurement is unreadable; this export remains unverified.')
    if values[-1]=='-inf': return None,True
    value=float(values[-1])
    if not math.isfinite(value): raise ValueError('The audio true-peak measurement is invalid; this export remains unverified.')
    return value,False


@dataclass(frozen=True)
class AudioEffects:
    gain_db: float = 0
    highpass_hz: float | None = None
    lowpass_hz: float | None = None
    compressor: bool = False
    echo_delay_ms: float | None = None
    echo_decay: float = .3

    def validate(self) -> None:
        def number(value, lower, upper):
            return not isinstance(value, bool) and isinstance(value, (float, int)) and math.isfinite(value) and lower <= value <= upper
        if not number(self.gain_db, -60, 18) or not isinstance(self.compressor, bool):
            raise ValueError('Gain must be -60…18dB and compressor must be a Boolean.')
        if self.highpass_hz is not None and not number(self.highpass_hz, 20, 2000): raise ValueError('High-pass must be 20…2000Hz.')
        if self.lowpass_hz is not None and not number(self.lowpass_hz, 2000, 22000): raise ValueError('Low-pass must be 2000…22000Hz.')
        if self.echo_delay_ms is not None and not number(self.echo_delay_ms, 1, 500): raise ValueError('Echo delay must be 1…500ms.')
        if not number(self.echo_decay, 0, .85): raise ValueError('Echo decay must be 0…0.85.')

    def filters(self) -> str:
        self.validate()
        chain = []
        if self.highpass_hz is not None: chain.append(f'highpass=f={self.highpass_hz}')
        if self.lowpass_hz is not None: chain.append(f'lowpass=f={self.lowpass_hz}')
        if self.compressor: chain.append('acompressor=threshold=0.125:ratio=3:attack=10:release=100:makeup=1')
        if self.echo_delay_ms is not None: chain.append(f'aecho=0.8:0.9:{self.echo_delay_ms}:{self.echo_decay}')
        chain += [f'volume={self.gain_db}dB', 'alimiter=limit=0.95:level=false:latency=true']
        return ','.join(chain)


@dataclass(frozen=True)
class SoundCue:
    source: Path
    at: float = 0
    gain_db: float = -12

    def validate(self, duration: float) -> None:
        if not self.source.is_file() or any(isinstance(x,bool) or not isinstance(x,(int,float)) or not math.isfinite(x) for x in (self.at,self.gain_db)) or not 0<=self.at<duration or not -60<=self.gain_db<=12:
            raise ValueError('Choose an available local sound, a time inside the export, and a gain of -60…12dB.')


@dataclass
class Layer:
    source: Path
    at: float
    start: float
    duration: float
    name: str
    lane: int = 0
    role: str = C.ROLE_DIALOGUE
    audio_only: bool = False
    video_only: bool = False
    gain_db: float = 0
    scale: float = 1
    position: tuple[float, float] = (0, 0)
    conform: str = 'fit'
    processed_index: int | None = None


def static_transform(element: ET.Element) -> tuple[float, tuple[float, float]]:
    transform = element.find('adjust-transform')
    if transform is None or transform.get('enabled') == '0': return 1, (0, 0)
    if transform.get('rotation', '0') != '0' or transform.get('anchor', '0 0') != '0 0' or transform.get('tracking'):
        raise ValueError('Rotated, anchored or tracked framing requires review in Final Cut before local export.')
    values = {'scale': transform.get('scale', '1 1'), 'position': transform.get('position', '0 0')}
    for param in transform.findall('param'):
        name = param.get('name')
        frames = param.findall('keyframeAnimation/keyframe')
        unique = {frame.get('value') for frame in frames}
        if name not in values or not frames or len(unique) != 1:
            raise ValueError('Animated framing requires review in Final Cut before this local derivative export.')
        values[name] = unique.pop()
    scale = tuple(map(float, values['scale'].split()))
    position = tuple(map(float, values['position'].split()))
    if len(scale) != 2 or len(position) != 2 or not all(math.isfinite(v) for v in (*scale, *position)) or scale[0] != scale[1] or not .1 <= scale[0] <= 4:
        raise ValueError('Unsupported or invalid framing transform.')
    return scale[0], position


def read_timeline(path: Path, *, expected_sha: str | None = None) -> tuple[float, list[Layer], list[Layer], list[tuple[float,str]], tuple[int,int]]:
    data = path.read_bytes()
    if expected_sha is not None and hashlib.sha256(data).hexdigest()!=expected_sha:
        raise ValueError('The saved parent changed before parsing; create the export again from a verified version.')
    duration = final_sequence_duration(data)  # rejects entities/external DTDs before ElementTree
    root = ET.fromstring(data)
    sequence = root.find('library/event/project/sequence')
    if sequence.get('tcStart', '0s') != '0s': raise ValueError('Nonzero timeline timecode origin is unsupported.')
    formats = {item.get('id'):item for item in root.findall('resources/format')}
    fmt = formats.get(sequence.get('format'))
    if fmt is None or seconds(fmt.get('frameDuration')) != C.FPS_DEN / C.FPS_NUM:
        raise ValueError('The saved timeline must use the supported 24000/1001 timebase.')
    dimensions = (int(fmt.get('width')), int(fmt.get('height')))
    sources = {}
    for asset in root.findall('resources/asset'):
        reps = asset.findall('media-rep')
        if len(reps) != 1: raise ValueError('Each media asset requires one original-media reference.')
        uri = urlparse(reps[0].get('src', ''))
        if uri.scheme != 'file' or uri.netloc not in ('', 'localhost'): raise ValueError('Only local media is supported.')
        source = Path(unquote(uri.path))
        if not source.is_file(): raise ValueError(f'Media unavailable: {source.name}')
        if asset.get('id') in sources: raise ValueError('Duplicate asset identity.')
        sources[asset.get('id')] = source.resolve()

    def layer(element, at, lane=0):
        allowed = {'adjust-conform','adjust-transform','adjust-volume','asset-clip','video','marker','chapter-marker','note'}
        if any(child.tag not in allowed for child in element): raise ValueError('An unsupported effect or nested timeline requires Final Cut review before local export.')
        if element.get('enabled', '1') != '1': raise ValueError('Disabled timeline items require Final Cut review.')
        if element.get('ref') not in sources: raise ValueError('An asset reference is missing.')
        gain = element.find('adjust-volume')
        if gain is not None and len(gain): raise ValueError('Animated volume requires Final Cut review before this local derivative export.')
        amount = 0 if gain is None else float(gain.get('amount', '').removesuffix('dB'))
        if not math.isfinite(amount) or not -96 <= amount <= 24: raise ValueError('Invalid audio gain.')
        scale, position = static_transform(element)
        conform = element.find('adjust-conform')
        mode = 'fit' if conform is None else conform.get('type', 'fit')
        if mode not in ('fit', 'fill'): raise ValueError('Native-size conform requires Final Cut review.')
        return Layer(sources[element.get('ref')], at, seconds(element.get('start','0s')),
                     seconds(element.get('duration')), element.get('name',''), lane,
                     element.get('audioRole', element.get('videoRole', element.get('role', C.ROLE_DIALOGUE))),
                     element.get('srcEnable') == 'audio' or lane < 0,
                     element.tag == 'video' or element.get('srcEnable') == 'video', amount, scale, position, mode)

    primary, connected, chapters = [], [], []
    spine = sequence.find('spine')
    if spine is None: raise ValueError('Missing primary storyline.')
    for element in spine:
        if element.tag != 'asset-clip': raise ValueError('Only Clauto asset-clip storylines can be exported locally; review other edits in Final Cut.')
        item = layer(element, seconds(element.get('offset','0s')))
        if item.audio_only or item.duration <= 0: raise ValueError('Primary clips need video and a positive duration.')
        primary.append(item)
        for child in element:
            if child.tag in ('asset-clip','video'):
                lane = int(child.get('lane','0'))
                if lane == 0 or any(x.tag in ('asset-clip','video') for x in child): raise ValueError('Nested connected storylines require Final Cut review.')
                connected.append(layer(child, item.at + seconds(child.get('offset','0s')) - item.start, lane))
            elif child.tag == 'chapter-marker':
                chapters.append((item.at + seconds(child.get('start','0s')) - item.start, child.get('value','Chapter')))
    cursor = 0
    for item in primary:
        if abs(item.at - cursor) > 1e-6: raise ValueError('Gaps or overlapping primary clips require Final Cut review.')
        cursor = item.at + item.duration
    if not primary or abs(cursor-duration) > 1e-6: raise ValueError('Primary clips do not match the sequence duration.')
    return duration, primary, connected, chapters, dimensions


def trim_layers(layers: list[Layer], start: float, end: float) -> list[Layer]:
    out = []
    for item in layers:
        lo, hi = max(start, item.at), min(end, item.at + item.duration)
        if hi <= lo: continue
        trimmed = copy.copy(item)
        trimmed.at, trimmed.start, trimmed.duration = lo-start, item.start+lo-item.at, hi-lo
        out.append(trimmed)
    return out


def framing(item: Layer, width: int, height: int, alpha=False) -> str:
    # FCP positions are expressed as percentages of sequence height, positive y upward.
    fit = 'increase' if item.conform == 'fill' else 'decrease'
    pixel = 'rgba' if alpha else 'yuv420p'
    sw, sh = max(2, round(width * item.scale / 2)*2), max(2, round(height * item.scale / 2)*2)
    x, y = round(item.position[0] * height / 100), -round(item.position[1] * height / 100)
    return (f'scale={sw}:{sh}:force_original_aspect_ratio={fit},format={pixel},'
            f'pad=max(iw\\,{width + abs(x)*2}):max(ih\\,{height + abs(y)*2}):(ow-iw)/2:(oh-ih)/2:color=black@0,'
            f'crop={width}:{height}:(iw-ow)/2-{x}:(ih-oh)/2-{y},setsar=1')


def audio_derivative(item: Layer, effects: AudioEffects, output: Path) -> Path:
    run(['ffmpeg','-nostdin','-v','error','-ss',str(item.start),'-i',str(item.source),'-vn',
         '-af',f'volume={item.gain_db}dB,{effects.filters()},atrim=duration={item.duration},apad=whole_dur={item.duration}',
         '-t',str(item.duration),'-ar','48000','-ac','2','-c:a','pcm_f32le','-n',str(output)])
    info = FX.probe(output)
    if not info['has_audio'] or abs(info['duration']-item.duration) > 1/48000: raise ValueError('Processed audio duration changed.')
    return output


def remap_captions(source: Path, output: Path, start: float, end: float, aspect: str, resolution: str, expected_sha: str | None = None) -> Path:
    data = source.read_bytes()
    if expected_sha is not None and hashlib.sha256(data).hexdigest()!=expected_sha: raise ValueError('Captions changed before export; create a new verified export.')
    parser = expat.ParserCreate()
    def refuse(*args): raise ValueError('Caption declarations are unsupported.')
    parser.StartDoctypeDeclHandler = refuse; parser.EntityDeclHandler = refuse; parser.ExternalEntityRefHandler = refuse
    parser.Parse(data,True)
    tree = ET.ElementTree(ET.fromstring(data))
    ns = {'t':'http://www.w3.org/ns/ttml'}
    def time(text):
        parts = list(map(int, text.split(':')))
        if len(parts) != 4 or parts[3] >= 24: raise ValueError('Caption times must be supported SMPTE frames.')
        return ((parts[0]*3600+parts[1]*60+parts[2])*24+parts[3]) * C.FPS_DEN / C.FPS_NUM
    for div in tree.findall('.//t:div', ns):
        for paragraph in list(div):
            if paragraph.tag != '{'+ns['t']+'}p': raise ValueError('Unsupported caption structure.')
            a, b = time(paragraph.get('begin','')), time(paragraph.get('end',''))
            lo, hi = max(a,start), min(b,end)
            if hi <= lo: div.remove(paragraph); continue
            paragraph.set('begin', FX.smpte(lo-start)); paragraph.set('end', FX.smpte(hi-start))
    if aspect == '9:16':
        style_ns = '{http://www.w3.org/ns/ttml#styling}'
        for region in tree.findall('.//t:region', ns):
            region.set(style_ns+'origin','6% 60%'); region.set(style_ns+'extent','72% 10%')
    tree.write(output, encoding='utf-8', xml_declaration=True)
    return output


def caption_ass(source: Path, output: Path, aspect: str, resolution: str) -> Path:
    ns = {'t':'http://www.w3.org/ns/ttml'}
    spec = C.canvas_spec(aspect,resolution)
    w,h = spec['author']; size = round(46*spec['pixel_scale'])
    def stamp(text):
        hh,mm,ss,ff = map(int,text.split(':'))
        value = ((hh*3600+mm*60+ss)*24+ff)*C.FPS_DEN/C.FPS_NUM
        centis = round(value*100); hours, rem = divmod(centis,360000); mins,rem=divmod(rem,6000); secs,cs=divmod(rem,100)
        return f'{hours}:{mins:02d}:{secs:02d}.{cs:02d}'
    lines = ['[Script Info]',f'PlayResX: {w}',f'PlayResY: {h}','[V4+ Styles]',
             'Format: Name, Fontname, Fontsize, PrimaryColour, BackColour, Bold, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
             f'Style: Default,Arial,{size},&H00FFFFFF,&H90000000,-1,3,2,0,2,{spec["margin_left"]},{spec["margin_right"]},{h-spec["caption_baseline"]},1',
             '[Events]','Format: Layer, Start, End, Style, Text']
    for paragraph in ET.parse(source).findall('.//t:p',ns):
        def content(element):
            result=element.text or ''
            for child in element:
                result += '\n' if child.tag=='{'+ns['t']+'}br' else content(child)
                result += child.tail or ''
            return result
        text = content(paragraph).replace('\\','\\\\').replace('{','\\{').replace('}','\\}').replace('\n','\\N')
        lines.append(f'Dialogue: 0,{stamp(paragraph.get("begin"))},{stamp(paragraph.get("end"))},Default,{text}')
    output.write_text('\n'.join(lines)+'\n')
    return output


def render(primary: list[Layer], connected: list[Layer], folder: Path, aspect: str, resolution: str, captions: Path | None = None) -> Path:
    width,height = C.canvas_spec(aspect,resolution)['author']
    parts = []
    for index,item in enumerate(primary):
        part = folder / f'part-{index:04d}.mp4'
        filters = framing(item,width,height) + ',fps='+C.FPS_STR
        info = FX.probe(item.source)
        args = ['ffmpeg','-nostdin','-v','error','-ss',str(item.start),'-i',str(item.source)]
        audio = next((x for x in connected if x.audio_only and x.processed_index == index),None)
        if audio:
            args += ['-i',str(audio.source)]
            audio_map = '1:a:0'
        elif info['has_audio'] and not item.video_only:
            audio_map = '0:a:0'
        else:
            args += ['-f','lavfi','-i','anullsrc=r=48000:cl=stereo']; audio_map = '1:a:0'
        run(args + ['-t',str(item.duration),'-vf',filters,'-map','0:v:0','-map',audio_map,
                    '-af',f'volume={item.gain_db if not audio else 0}dB','-ar','48000','-ac','2',
                    '-c:v','libx264','-preset','veryfast','-crf','18','-pix_fmt','yuv420p','-c:a','pcm_s16le',
                    '-f','matroska','-n',str(part)])
        parts.append(part)
    concat = folder/'parts.txt'
    concat.write_text(''.join("file '"+str(p).replace("'", "'\\''")+"'\n" for p in parts))
    base = folder/'base.mkv'
    run(['ffmpeg','-nostdin','-v','error','-f','concat','-safe','0','-i',str(concat),'-c','copy','-n',str(base)])
    args = ['ffmpeg','-nostdin','-v','error','-i',str(base)]
    filters, video, audio = [], '[0:v]', '[0:a]'
    # Positive lanes stack above the picture. Audio stays independent and is never retimed.
    layers = sorted([x for x in connected if x.processed_index is None],key=lambda x:x.lane)
    audio_labels = [audio]
    for index,item in enumerate(layers,1):
        args += ['-ss',str(item.start),'-i',str(item.source)]
        if item.audio_only:
            filters.append(f'[{index}:a]atrim=duration={item.duration},asetpts=PTS-STARTPTS,volume={item.gain_db}dB,adelay={round(item.at*48000)}S:all=1[au{index}]')
            audio_labels.append(f'[au{index}]')
        else:
            if not item.video_only and FX.probe(item.source)['has_audio']:
                raise ValueError('A connected picture with audio needs an explicit video-only or audio-only role before export.')
            filters.append(f'[{index}:v]{framing(item,width,height,alpha=True)},trim=duration={item.duration},setpts=PTS-STARTPTS+{item.at}/TB[lay{index}]')
            filters.append(f'{video}[lay{index}]overlay=eof_action=pass:repeatlast=0:enable=between(t\\,{item.at}\\,{item.at+item.duration})[v{index}]')
            video=f'[v{index}]'
    if captions is not None:
        # A fixed safe leaf is generated inside this new folder; avoid interpolating an input filename.
        caption_ass(captions,folder/'captions.ass',aspect,resolution)
        filters.append(f"{video}subtitles=filename=captions.ass[captioned]"); video='[captioned]'
    if len(audio_labels)>1:
        filters.append(''.join(audio_labels)+f'amix=inputs={len(audio_labels)}:duration=first:normalize=0[mixed]'); audio='[mixed]'
    out = folder/'review.mp4'
    if filters: args += ['-filter_complex',';'.join(filters)]
    run(args+['-map',video if video!='[0:v]' else '0:v:0','-map',audio if audio!='[0:a]' else '0:a:0',
              '-t',str(sum(x.duration for x in primary)),'-c:v','libx264','-preset','veryfast','-crf','18',
              '-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-movflags','+faststart','-n',str(out)],directory=folder)
    run(['ffmpeg','-nostdin','-v','error','-i',str(out),'-f','null','-'])
    probe = json.loads(subprocess.run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(out)],capture_output=True,check=True).stdout)
    v = next(x for x in probe['streams'] if x['codec_type']=='video')
    if (v['width'],v['height']) != (width,height) or abs(float(probe['format']['duration'])-sum(x.duration for x in primary)) > 1/C.FPS:
        raise ValueError('Encoded dimensions or duration do not match the chosen output.')
    meter=subprocess.run(['ffmpeg','-nostdin','-v','info','-i',str(out),'-vn','-af','ebur128=peak=true','-f','null','-'],capture_output=True,check=True)
    peak,silence=measured_true_peak(meter.stderr.decode(errors='replace'))
    if peak is not None and peak>0: raise ValueError(f'The export measures {peak:.1f}dBFS true peak. Lower dialogue or sound-effect gain before accepting it.')
    (folder/'decode-verification.json').write_text(json.dumps({'full_decode_passed':True,'probe':probe,'audio_true_peak_dbfs':peak,'audio_verified_silence':silence,'audio_peak_gate_passed':True},indent=2))
    # Intermediate files belong only to this derivative and are recoverable from its recipe.
    for path in [*parts,base,concat]: path.unlink()
    return out


def derive(timeline: Path, destination: Path, *, aspect='9:16', resolution='1080p', start=0.0, end=None,
           conform='fit', position=(0.0,0.0), effects: AudioEffects | None = None, captions: Path | None = None,
           sound: SoundCue | None = None) -> Path:
    if aspect not in C.ASPECTS or conform not in ('fit','fill'): raise ValueError('Unsupported aspect or framing mode.')
    if destination.is_symlink(): raise ValueError('An export folder cannot be a symbolic-link alias.')
    timeline, destination = timeline.resolve(), destination.resolve()
    captions = captions.resolve() if captions else None
    C.canvas_spec(aspect,resolution)
    parent_hash = sha(timeline)
    duration, primary, connected, chapters, original_dimensions = read_timeline(timeline,expected_sha=parent_hash)
    end = duration if end is None else end
    if not all(isinstance(x,(int,float)) and not isinstance(x,bool) and math.isfinite(x) for x in (start,end,*position)) or start < 0 or end > duration+1e-9 or end <= start or any(abs(x)>100 for x in position):
        raise ValueError('Select a finite range within this saved version and framing positions within -100…100%.')
    start,end = C.snap_seconds(start),C.snap_seconds(end)
    if end <= start: raise ValueError('The selected range is shorter than one frame.')
    if destination.exists(): raise ValueError('An existing derivative is immutable; choose a new folder.')
    if effects is not None: effects.validate()
    caption_hash = sha(captions) if captions else None
    primary,connected = trim_layers(primary,start,end),trim_layers(connected,start,end)
    sound_manifest=None
    if sound:
        sound.validate(end-start)
        info=FX.probe(sound.source)
        if not info['has_audio'] or info['duration']<=0: raise ValueError('The selected sound has no usable audio.')
        at=C.snap_seconds(sound.at)
        if at>=end-start: raise ValueError('The sound lands after the export on its frame grid.')
        span=min(info['duration'],end-start-at)
        connected.append(Layer(sound.source.resolve(),at,0,span,'Selected sound effect',C.LANE_FOLEY,'effects.foley',audio_only=True,gain_db=sound.gain_db))
        sound_manifest={'source':str(sound.source.resolve()),'at':at,'gain_db':sound.gain_db,'duration':span}
    sources = sorted({x.source for x in primary+connected})
    for item in primary+connected:
        info=FX.probe(item.source)
        if item.duration<=0 or item.start<0 or item.start+item.duration>info['duration']+1/C.FPS:
            raise ValueError(f'The selected media range exceeds {item.source.name}; missing footage cannot be held or padded.')
        if (not item.audio_only and not info['has_video']) or (item.audio_only and not info['has_audio']):
            raise ValueError(f'A required media stream is missing from {item.source.name}.')
    source_hashes = {str(x):sha(x) for x in sources}
    destination.mkdir(parents=True,exist_ok=False)
    try:
        for index,item in enumerate(primary):
            item.conform=conform; item.position=(item.position[0]+position[0],item.position[1]+position[1])
            if effects is not None and FX.probe(item.source)['has_audio'] and not item.video_only:
                audio=audio_derivative(item,effects,destination/f'dialogue-{index:04d}.wav')
                item.video_only=True
                connected.append(Layer(audio,item.at,0,item.duration,f'Processed dialogue {index}',-1,C.ROLE_DIALOGUE,audio_only=True,processed_index=index))
        exported=destination/'timeline.fcpxml'
        builder=FX.FCPXMLBuilder(f'{timeline.stem} — derivative',aspect,resolution=resolution)
        clips=[FX.Clip(x.source,x.at,x.start,x.duration,name=x.name,gain_db=x.gain_db,scale=x.scale,
                       conform=x.conform,position=x.position,audio_enabled=not x.video_only) for x in primary]
        layers=[FX.Connected(x.source,x.at,x.duration,name=x.name,lane=x.lane,role=x.role,start=x.start,
                             audio=x.audio_only,video_only=not x.audio_only,gain_db=x.gain_db if x.audio_only else None,
                             scale=x.scale,position=x.position,conform=x.conform if not x.audio_only else None) for x in connected]
        builder.write(builder.build(clips,layers,[(t-start,title) for t,title in chapters if start<=t<end]),exported)
        problems=FX.validate(exported)
        if problems: raise ValueError('Derived timeline validation failed: '+'; '.join(problems))
        caption_out=remap_captions(captions,destination/'captions.itt',start,end,aspect,resolution,expected_sha=caption_hash) if captions else None
        out=render(primary,connected,destination,aspect,resolution,caption_out)
        if sha(timeline)!=parent_hash or any(sha(Path(p))!=h for p,h in source_hashes.items()) or (captions and sha(captions)!=caption_hash): raise ValueError('A source changed during export; derivative is unverified.')
        outputs={p.name:sha(p) for p in destination.iterdir() if p.is_file()}
        recipe={'schema_version':1,'state':'complete','parent_timeline':str(timeline.resolve()),'parent_sha256':parent_hash,
                'source_sha256':source_hashes,'selected_range_seconds':[start,end],'aspect':aspect,'resolution':resolution,
                'framing':{'conform':conform,'position_percent_of_height':list(position)},
                'audio_effects':asdict(effects) if effects else None,'effects_revision':'ffmpeg-local-v1',
                'sound_effect':sound_manifest,'engine_version':C.ENGINE_VERSION,
                'caption_source':str(captions.resolve()) if captions else None,'caption_sha256':caption_hash,
                'output_sha256':outputs,'full_decode_passed':True,'schema_checked':FX.dtd_problems(exported) is not None,
                'upscaled_sources':[str(x.source) for x in primary if FX.probe(x.source).get('width',0)<C.canvas_spec(aspect,resolution)['author'][0] or FX.probe(x.source).get('height',0)<C.canvas_spec(aspect,resolution)['author'][1]],
                'audio_tail_policy':'Effects keep the selected interval duration; delayed tails outside it are trimmed.'}
        (destination/'derivative.json').write_text(json.dumps(recipe,indent=2)+'\n')
        return out
    except BaseException as exc:
        (destination/'failed.json').write_text(json.dumps({'state':'failed','detail':str(exc),'parent_unchanged_required':True},indent=2))
        raise


def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('timeline',type=Path); ap.add_argument('destination',type=Path)
    ap.add_argument('--aspect',choices=list(C.ASPECTS),default='9:16')
    ap.add_argument('--resolution',choices=list(C.RESOLUTIONS),default=C.DEFAULT_RESOLUTION)
    ap.add_argument('--start',type=float,default=0); ap.add_argument('--end',type=float)
    ap.add_argument('--framing',choices=['fit','fill'],default='fit')
    ap.add_argument('--x',type=float,default=0); ap.add_argument('--y',type=float,default=0)
    ap.add_argument('--audio-effects',help='Validated AudioEffects JSON, with no external plugins')
    ap.add_argument('--captions',type=Path)
    ap.add_argument('--sound',type=Path); ap.add_argument('--sound-at',type=float,default=0)
    ap.add_argument('--sound-gain-db',type=float,default=-12)
    args=ap.parse_args(argv)
    try:
        effects=AudioEffects(**json.loads(args.audio_effects)) if args.audio_effects else None
        out=derive(args.timeline,args.destination,aspect=args.aspect,resolution=args.resolution,start=args.start,end=args.end,
                   conform=args.framing,position=(args.x,args.y),effects=effects,captions=args.captions,
                   sound=SoundCue(args.sound,args.sound_at,args.sound_gain_db) if args.sound else None)
        print(json.dumps({'state':'complete','review':str(out),'receipt':str(args.destination/'derivative.json')})); return 0
    except (ValueError,RuntimeError,OSError,TypeError,KeyError,ArithmeticError,expat.ExpatError,ET.ParseError,subprocess.CalledProcessError) as exc:
        print(json.dumps({'state':'failed','detail':str(exc)})); return 1


if __name__=='__main__': raise SystemExit(main())
