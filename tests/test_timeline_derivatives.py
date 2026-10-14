import json
import subprocess
from pathlib import Path
from xml.etree import ElementTree as ET
from PIL import Image, ImageDraw

import numpy as np
import pytest
import config as C
import fcpxml as FX
import timeline_derivatives as D


def timeline(video, path, *, duration=1, connected=None):
    builder=FX.FCPXMLBuilder('Synthetic derivative')
    builder.write(builder.build([FX.Clip(video,0,0,duration)],connected or []),path)
    return path


@pytest.mark.parametrize('aspect',['16:9','9:16'])
@pytest.mark.parametrize('resolution',['720p','1080p','2160p'])
def test_actual_encoded_dimensions_decode_and_preserved_parent(tmp_path,video,aspect,resolution):
    parent=timeline(video,tmp_path/'parent.fcpxml')
    before=D.sha(parent),D.sha(video)
    end=C.snap_seconds(.25)
    output=D.derive(parent,tmp_path/'derived',aspect=aspect,resolution=resolution,end=end)
    receipt=json.loads((output.parent/'derivative.json').read_text())
    assert receipt['state']=='complete' and receipt['full_decode_passed']
    info=FX.probe(output)
    assert (info['width'],info['height'])==C.canvas_spec(aspect,resolution)['author']
    assert abs(info['duration']-end)<1/C.FPS
    assert before==(D.sha(parent),D.sha(video))
    assert D.sha(output)==receipt['output_sha256']['review.mp4']
    assert FX.validate(output.parent/'timeline.fcpxml')==[]
    assert FX.dtd_problems(output.parent/'timeline.fcpxml') in (None,[])
    with pytest.raises(ValueError,match='immutable'): D.derive(parent,tmp_path/'derived',end=end)


def test_range_clipping_remaps_connected_media_and_captions(tmp_path,video):
    step=1/C.FPS
    connected=[FX.Connected(video,step,step*4,start=step*2,video_only=True)]
    parent=timeline(video,tmp_path/'parent.fcpxml',duration=step*12,connected=connected)
    duration,primary,layers,_,_=D.read_timeline(parent)
    clipped=D.trim_layers(layers,step*3,step*8)
    assert len(clipped)==1 and clipped[0].at==0
    assert clipped[0].start==pytest.approx(step*4)
    assert clipped[0].duration==pytest.approx(step*2)
    captions,_=FX.build_itt([{'word':'Keep','start':step,'end':step*6}, {'word':'later','start':2,'end':3}],tmp_path/'parent.itt')
    dest=tmp_path/'remap.itt'
    D.remap_captions(captions,dest,step*3,step*8,'9:16','720p')
    root=ET.parse(dest)
    paragraphs=root.findall('.//{http://www.w3.org/ns/ttml}p')
    assert len(paragraphs)==1 and paragraphs[0].get('begin')=='00:00:00:00'
    assert 'Keep' in dest.read_text() and 'later' not in dest.read_text()
    assert '72% 10%' in dest.read_text()


def test_effects_render_actual_pcm_with_timing_and_editable_handoff(tmp_path,video):
    source=tmp_path/'tone.mp4'
    D.run(['ffmpeg','-nostdin','-v','error','-f','lavfi','-i','color=c=navy:s=320x180:r=24000/1001',
           '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','1','-c:v','libx264','-c:a','aac','-n',str(source)])
    parent=timeline(source,tmp_path/'parent.fcpxml')
    output=D.derive(parent,tmp_path/'effect',aspect='16:9',resolution='720p',end=C.snap_seconds(.5),effects=D.AudioEffects(gain_db=6,highpass_hz=40))
    pcm=output.parent/'dialogue-0000.wav'
    values=subprocess.run(['ffmpeg','-v','error','-i',str(pcm),'-f','f32le','-ac','1','-'],capture_output=True,check=True).stdout
    samples=np.frombuffer(values,dtype='<f4')
    assert len(samples)/48000==pytest.approx(C.snap_seconds(.5),abs=1/48000)
    assert np.max(np.abs(samples))<=.96
    assert np.sqrt(np.mean(samples[2000:]**2))>.14  # 6dB gain changes the 0.125-amplitude tone
    root=ET.parse(output.parent/'timeline.fcpxml')
    primary=root.find('.//spine/asset-clip')
    assert primary.get('srcEnable')=='video'
    audio=primary.find('asset-clip')
    assert audio is not None and audio.get('audioRole')==C.ROLE_DIALOGUE
    assert FX.dtd_problems(output.parent/'timeline.fcpxml') in (None,[])
    receipt=json.loads((output.parent/'derivative.json').read_text())
    assert receipt['audio_effects']['gain_db']==6 and receipt['source_sha256'][str(source)]==D.sha(source)


def test_actual_alpha_overlay_and_caption_are_visible_in_apostrophe_export(tmp_path):
    source=tmp_path/'base.mp4'
    D.run(['ffmpeg','-nostdin','-v','error','-f','lavfi','-i','color=c=navy:s=320x180:r=24000/1001',
           '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','1','-c:v','libx264','-c:a','aac','-n',str(source)])
    image=Image.new('RGBA',(320,180)); ImageDraw.Draw(image).rectangle((80,40,240,140),fill=(0,240,20,255))
    image.save(tmp_path/'layer.png')
    layer=tmp_path/'layer.mov'
    D.run(['ffmpeg','-nostdin','-v','error','-loop','1','-i',str(tmp_path/'layer.png'),'-t','1','-r',C.FPS_STR,
           '-c:v','prores_ks','-profile:v','4','-pix_fmt','yuva444p10le','-n',str(layer)])
    parent=timeline(source,tmp_path/'parent.fcpxml',connected=[FX.Connected(layer,0,C.snap_seconds(.5),video_only=True)])
    captions,_=FX.build_itt([{'word':'VISIBLE','start':0,'end':.4}],tmp_path/'parent.itt')
    output=D.derive(parent,tmp_path/"Katie's visible export",aspect='16:9',resolution='720p',end=C.snap_seconds(.5),captions=captions)
    raw=subprocess.run(['ffmpeg','-v','error','-ss','0.25','-i',str(output),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'],capture_output=True,check=True).stdout
    pixels=np.frombuffer(raw,np.uint8).reshape(720,1280,3)
    assert pixels[360,640,1]>200 and pixels[360,640,0]<40  # alpha layer survives
    assert np.sum(np.all(pixels[540:630,200:1080]>210,axis=-1))>200  # visible caption in safe area
    assert (output.parent/'captions.itt').is_file()


def test_connected_framing_is_preserved_in_editable_handoff(tmp_path,video):
    parent=timeline(video,tmp_path/'parent.fcpxml',connected=[FX.Connected(video,0,.5,video_only=True,scale=.5,position=(10,0),conform='fit')])
    output=D.derive(parent,tmp_path/'framed',aspect='16:9',resolution='720p',end=C.snap_seconds(.5))
    element=ET.parse(output.parent/'timeline.fcpxml').find('.//spine/asset-clip/video/adjust-transform')
    assert element is not None and element.get('scale')=='0.500000 0.500000' and element.get('position')=='10.000000 0.000000'


def test_actual_local_sound_effect_timing_and_peak_gate(tmp_path):
    source=tmp_path/'silent.mp4'; sound=tmp_path/'effect.wav'
    D.run(['ffmpeg','-nostdin','-v','error','-f','lavfi','-i','color=c=navy:s=320x180:r=24000/1001',
           '-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t','1','-c:v','libx264','-c:a','aac','-n',str(source)])
    D.run(['ffmpeg','-nostdin','-v','error','-f','lavfi','-i','sine=frequency=880:sample_rate=48000','-t','0.25','-n',str(sound)])
    parent=timeline(source,tmp_path/'parent.fcpxml')
    at=3/C.FPS
    out=D.derive(parent,tmp_path/'sound',aspect='16:9',resolution='720p',end=C.snap_seconds(.5),sound=D.SoundCue(sound,at,0))
    data=subprocess.run(['ffmpeg','-v','error','-i',str(out),'-f','f32le','-ac','1','-'],capture_output=True,check=True).stdout
    samples=np.frombuffer(data,dtype='<f4')
    assert np.max(np.abs(samples[:2000]))<.001
    assert np.sqrt(np.mean(samples[8000:12000]**2))>.03
    root=ET.parse(out.parent/'timeline.fcpxml')
    effect=root.find('.//spine/asset-clip/asset-clip')
    assert effect.get('audioRole')=='effects.foley' and effect.get('srcEnable')=='audio' and D.seconds(effect.get('offset'))==at
    receipt=json.loads((out.parent/'derivative.json').read_text())
    assert receipt['sound_effect']['at']==at and receipt['source_sha256'][str(sound)]==D.sha(sound)
    assert json.loads((out.parent/'decode-verification.json').read_text())['audio_peak_gate_passed']


def test_peak_measurement_distinguishes_verified_silence_from_unknown():
    assert D.measured_true_peak('True peak:\n Peak: -inf dBFS')==(None,True)
    assert D.measured_true_peak('True peak:\n Peak: -1.5 dBFS')==(-1.5,False)
    for invalid in ['', 'Peak: NaN dBFS','Peak: +inf dBFS','Peak: nonsense dBFS']:
        with pytest.raises(ValueError): D.measured_true_peak(invalid)


def test_malformed_xml_cli_returns_failed_json(tmp_path,capsys):
    path=tmp_path/'malformed.fcpxml'; path.write_text('<fcpxml>')
    assert D.main([str(path),str(tmp_path/'out')])==1
    result=json.loads(capsys.readouterr().out)
    assert result['state']=='failed' and not (tmp_path/'out').exists()


def test_parent_identity_is_bound_to_parsed_bytes_and_animated_volume_refused(tmp_path,video,monkeypatch):
    parent=timeline(video,tmp_path/'parent.fcpxml')
    original=D.read_timeline
    def changed_after_parse(path,**kwargs):
        result=original(path,**kwargs)
        path.write_text(path.read_text()+'\n')
        return result
    monkeypatch.setattr(D,'read_timeline',changed_after_parse)
    with pytest.raises(ValueError,match='changed during export'):
        D.derive(parent,tmp_path/'changed',aspect='16:9',resolution='720p',end=C.snap_seconds(.25))
    assert not (tmp_path/'changed/derivative.json').exists()
    monkeypatch.setattr(D,'read_timeline',original)
    data=parent.read_text().replace('<spine>','<spine>')
    root=ET.fromstring(data)
    clip=root.find('.//spine/asset-clip')
    gain=ET.SubElement(clip,'adjust-volume',amount='0dB')
    ET.SubElement(gain,'param',name='amount')
    path=tmp_path/'animated.fcpxml'; path.write_bytes(ET.tostring(root))
    with pytest.raises(ValueError,match='Animated volume'): D.read_timeline(path)


def test_unknown_effects_unsafe_xml_and_bad_parameters_are_refused(tmp_path,video):
    for settings in [D.AudioEffects(gain_db=float('nan')),D.AudioEffects(highpass_hz=2),D.AudioEffects(echo_decay=1),D.AudioEffects(compressor=1)]:
        with pytest.raises(ValueError): settings.validate()
    parent=timeline(video,tmp_path/'parent.fcpxml')
    for start,end in [(float('nan'),.4),(0,2),(.4,.2),(-1,.4)]:
        with pytest.raises(ValueError): D.derive(parent,tmp_path/'bad',start=start,end=end)
        assert not (tmp_path/'bad').exists()
    data=parent.read_text().replace('<!DOCTYPE fcpxml>','<!DOCTYPE fcpxml [<!ENTITY bad "1s">]>')
    (tmp_path/'unsafe.fcpxml').write_text(data)
    with pytest.raises(ValueError): D.read_timeline(tmp_path/'unsafe.fcpxml')
    data=parent.read_text().replace('<spine>','<spine><transition duration="1s"/>')
    (tmp_path/'unsupported.fcpxml').write_text(data)
    with pytest.raises(ValueError,match='Only Clauto'): D.read_timeline(tmp_path/'unsupported.fcpxml')
    with pytest.raises(ValueError):
        (tmp_path/'unsafe.itt').write_bytes('<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE tt [<!ENTITY x "bad">]><tt/>'.encode('utf-16'))
        D.remap_captions(tmp_path/'unsafe.itt',tmp_path/'out.itt',0,1,'9:16','720p')
