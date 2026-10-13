"""Render a labeled local A/B sync proof with ONLY camera A audio.

This is a review sample, not an accepted edit. Its explicit source/offset config
must come from waveform/clap matching rather than camera timestamps.
"""
import argparse
import json
import math
from pathlib import Path
import subprocess


def crop_filter(config, native_width, native_height):
    crop=config.get('b_crop')
    if crop is None:return ''
    if not isinstance(crop,list) or len(crop)!=4 or any(type(v) is not int for v in crop):
        raise ValueError('Crop must be integer x, y, width, height.')
    x,y,width,height=crop
    if x<0 or y<0 or width<1920 or height<1080 or native_width/width>1.5 or native_height/height>1.5 or x+width>native_width or y+height>native_height or width*9!=height*16:
        raise ValueError('B crop must stay within 150% total scale, preserve native 1080p, and fit the source at 16:9.')
    return f'crop={width}:{height}:{x}:{y},'


def probe_source(path):
    return json.loads(subprocess.run(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(path)],capture_output=True,check=True).stdout)


def validate_range(probe, start, duration, needs_audio=False):
    streams=[s for s in probe['streams'] if s['codec_type']=='video' or (needs_audio and s['codec_type']=='audio')]
    if not any(s['codec_type']=='video' for s in streams) or (needs_audio and not any(s['codec_type']=='audio' for s in streams)):
        raise ValueError('Required camera video/audio stream is missing.')
    for stream in streams:
        try:end=float(stream.get('duration',probe.get('format',{}).get('duration',0)))
        except (TypeError,ValueError):raise ValueError('Source duration is unavailable.')
        if not math.isfinite(end) or end<=0 or start+duration>end:
            raise ValueError('Requested proof exceeds a source stream; never freeze missing footage.')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('config',type=Path);ap.add_argument('destination',type=Path)
    args=ap.parse_args();c=json.loads(args.config.read_text())
    output=args.destination
    if output.exists() or output.with_suffix('.proof.json').exists():raise ValueError('Existing proof/evidence is preserved; choose a new filename.')
    a=Path(c['a']);b=Path(c['b']);start=float(c['a_start']);offset=float(c['b_minus_a']);duration=float(c['duration'])
    if not a.is_file() or not b.is_file() or not all(math.isfinite(v) for v in [start,offset,duration]) or start<0 or start+offset<0 or not 1<=duration<=60:raise ValueError('Invalid proof inputs.')
    source_probe=probe_source(b)
    validate_range(probe_source(a),start,duration,needs_audio=True)
    validate_range(source_probe,start+offset,duration)
    source_video=next(s for s in source_probe['streams'] if s['codec_type']=='video')
    crop=crop_filter(c,source_video['width'],source_video['height'])
    before={str(p):(p.stat().st_size,p.stat().st_mtime_ns) for p in [a,b]}
    font='/System/Library/Fonts/Supplemental/Arial.ttf'
    filters=("[0:v]scale=640:360,setsar=1,fps=24000/1001:round=near[left];"
        f"[1:v]{crop}scale=640:360,setsar=1,fps=24000/1001:round=near[right];"
        "[left][right]hstack=inputs=2,pad=1280:480:0:60:black,"
        f"drawtext=fontfile='{font}':text='CANON A - primary dialogue':x=20:y=18:fontsize=22:fontcolor=white,"
        f"drawtext=fontfile='{font}':text='ONE R B - {'tight crop' if crop else 'silent picture'}':x=660:y=18:fontsize=22:fontcolor=white,"
        f"drawtext=fontfile='{font}':text='SYNC PROOF ONLY - review clap and mouth alignment':x=20:y=436:fontsize=22:fontcolor=white[out]")
    command=['ffmpeg','-nostdin','-v','error','-ss',str(start),'-i',str(a),'-ss',str(start+offset),'-i',str(b),
        '-t',str(duration),'-filter_complex',filters,'-map','[out]','-map','0:a:0',
        '-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','160k',
        '-movflags','+faststart','-n',str(output)]
    subprocess.run(command,check=True)
    subprocess.run(['ffmpeg','-nostdin','-v','error','-i',str(output),'-f','null','-'],check=True)
    probe=probe_source(output)
    for stream in probe['streams']:
        if stream['codec_type'] in ['video','audio'] and abs(float(stream['duration'])-duration)>1001/24000:
            raise ValueError('Encoded proof duration changed; no success receipt written.')
    after={str(p):(p.stat().st_size,p.stat().st_mtime_ns) for p in [a,b]}
    receipt={'config':c,'audio_source':str(a),'b_audio_included':False,'same_time_duration_no_audio_speed_change':True,
        'source_stat_unchanged':before==after,'full_decode_passed':True,'probe':probe,'visual_review_accepted':False,
        'video_frame_quantization_limit_seconds':1001/24000,'not_a_full_or_accepted_edit':True}
    receipt_path=output.with_suffix('.proof.json')
    with receipt_path.open('x') as f:json.dump(receipt,f,indent=2)
    print(json.dumps({'proof':str(output),'bytes':output.stat().st_size,'full_decode_passed':True,'visual_review_accepted':False}))


if __name__=='__main__':main()
