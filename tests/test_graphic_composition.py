"""Composition protocol tests around real synthetic ffmpeg alpha movies.

The Python fixture does not claim Metal or font-production provenance. The native
Swift integration separately generates a real scene/cutout/custom-font revision.
"""
import copy
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from uuid import uuid4
from xml.etree import ElementTree as ET

import numpy as np
from PIL import Image, ImageDraw
import pytest
import config as C
import fcpxml as FX
import timeline_derivatives as D
from graphic_scene_cue import GraphicCue, fingerprint, strict_json, LABELS


def record(path):
    return {'sha256':D.sha(path),'byteCount':path.stat().st_size}


def write_manifest(folder, manifest, request):
    (folder/'revision.json').write_text(json.dumps(manifest,sort_keys=True)+'\n')
    request['manifestSHA256']=D.sha(folder/'revision.json')


@pytest.fixture(scope='module')
def protocol_movie(tmp_path_factory):
    root=tmp_path_factory.mktemp('graphic-protocol-fixture')
    folder=root/'revision';folder.mkdir()
    image=Image.new('RGBA',(320,240));draw=ImageDraw.Draw(image)
    draw.rectangle((70,50,250,190),fill=(0,240,20,255));draw.rectangle((8,8,24,24),fill=(30,40,240,128))
    image.save(folder/'frame-first.png');image.save(folder/'frame-last.png')
    D.run(['ffmpeg','-nostdin','-v','error','-loop','1','-framerate',C.FPS_STR,'-i',str(folder/'frame-first.png'),
           '-frames:v','12','-an','-c:v','prores_ks','-profile:v','4','-pix_fmt','yuva444p10le','-n',str(folder/'animation.mov')])
    raw=subprocess.run(['ffmpeg','-v','error','-i',str(folder/'animation.mov'),'-f','rawvideo','-pix_fmt','rgba','-'],capture_output=True,check=True).stdout
    frames=np.frombuffer(raw,np.uint8).reshape(12,240,320,4)
    alpha=np.asarray(image)[:,:,3].astype(np.int16)
    error=max(int(np.max(np.abs(frames[i,:,:,3].astype(np.int16)-alpha))) for i in (0,11))
    assert error<=2
    ids=[str(uuid4()).upper() for _ in range(3)];project,scene,revision=ids
    scene_data={'schemaVersion':1,'id':scene,'projectID':project,'scene':{'kind':'object','width':320,'height':240,'frameCount':12,'assumptions':[]}}
    (folder/'scene.json').write_text(json.dumps(scene_data))
    # These bounded byte records exercise the consumer protocol, not font parsing.
    (folder/'annotation-font.ttf').write_bytes(b'synthetic protocol fixture; not an actual font')
    (folder/'annotation-OFL.txt').write_text('Synthetic protocol fixture; no production font claim.\n')
    (folder/'timeline.fcpxml').write_text('<fcpxml version="1.11"/>')
    proof={'movie':record(folder/'animation.mov'),'width':320,'height':240,'frameCount':12,'durationValue':12012,
           'durationScale':24000,'codec':'ap4h','decodedEveryFrame':True,'maximumEndpointAlphaError':error}
    (folder/'decode-proof.json').write_text(json.dumps(proof))
    files={p.name:record(p) for p in folder.iterdir()}
    manifest={'schemaVersion':1,'id':revision,'sceneID':scene,'projectID':project,'draftSHA256':files['scene.json']['sha256'],
              'rendererVersion':'synthetic-protocol-fixture-not-Metal','metalShaderSHA256':hashlib.sha256(b'synthetic protocol only').hexdigest(),
              'validationLabel':LABELS['object'],'assumptions':[],'files':files,'proof':proof}
    request={'projectID':project,'sceneID':scene,'revisionID':revision,'manifestSHA256':'0'*64,'movieSHA256':files['animation.mov']['sha256'],
             'at':4/C.FPS,'sourceStart':2/C.FPS,'duration':6/C.FPS,'scale':.75,'x':10.0,'y':-5.0}
    write_manifest(folder,manifest,request)
    return folder,request


@pytest.fixture
def exported(tmp_path,protocol_movie):
    original,request=protocol_movie;folder=tmp_path/'selected-revision';shutil.copytree(original,folder)
    return folder,copy.deepcopy(request)


def parent(tmp_path):
    source=tmp_path/'base.mp4'
    D.run(['ffmpeg','-nostdin','-v','error','-f','lavfi','-i','color=c=navy:s=320x180:r=24000/1001',
           '-t',str(24/C.FPS),'-c:v','libx264','-pix_fmt','yuv420p','-n',str(source)])
    timeline=tmp_path/'parent.fcpxml';builder=FX.FCPXMLBuilder('Synthetic parent')
    builder.write(builder.build([FX.Clip(source,0,0,24/C.FPS)],[]),timeline)
    return source,timeline


def pixels(path,frame,width,height):
    data=subprocess.run(['ffmpeg','-v','error','-ss',str(frame/C.FPS),'-i',str(path),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'],capture_output=True,check=True).stdout
    return np.frombuffer(data,np.uint8).reshape(height,width,3)


@pytest.mark.parametrize('aspect',['16:9','9:16'])
def test_actual_composition_keeps_alpha_timing_transform_role_inputs_and_parent(tmp_path,exported,aspect):
    folder,request=exported;source,timeline=parent(tmp_path);before=D.sha(source),D.sha(timeline),D.sha(folder/'animation.mov')
    output=D.derive(timeline,tmp_path/'composed',aspect=aspect,resolution='720p',graphic=GraphicCue(folder/'revision.json',request))
    recipe=json.loads((output.parent/'derivative.json').read_text());metadata=recipe['generated_graphic']
    assert metadata['request']==request and metadata['source_frame_count']==12
    assert recipe['source_sha256'][str((folder/'animation.mov').resolve())]==request['movieSHA256']
    assert (output.parent/'graphic-revision.json').read_bytes()==(folder/'revision.json').read_bytes()
    assert (output.parent/'graphic-scene.json').read_bytes()==(folder/'scene.json').read_bytes()
    width,height=C.canvas_spec(aspect,'720p')['author']
    early,during,late=[pixels(output,n,width,height)[height//2,width//2] for n in (2,6,13)]
    assert early[1]<30 and early[2]>90
    assert during[1]>160 and during[0]<50
    assert late[1]<30 and late[2]>90
    _,_,layers,_,_=D.read_timeline(output.parent/'timeline.fcpxml')
    graphic=next(x for x in layers if x.name=='Clauto generated graphic')
    assert (graphic.at,graphic.start,graphic.duration)==pytest.approx((4/C.FPS,2/C.FPS,6/C.FPS))
    assert graphic.scale==.75 and graphic.position==(10,-5)
    node=ET.parse(output.parent/'timeline.fcpxml').find('.//video[@name="Clauto generated graphic"]')
    assert node is not None and node.get('role')==C.ROLE_GRAPHICS
    assert before==(D.sha(source),D.sha(timeline),D.sha(folder/'animation.mov'))
    assert recipe['full_decode_passed'] and FX.validate(output.parent/'timeline.fcpxml')==[]


@pytest.mark.parametrize('field,value',[
    ('at',True),('duration',.00001),('sourceStart',12/C.FPS),('at',2.0),
    ('manifestSHA256','0'*64),('movieSHA256','0'*64),('projectID',str(uuid4()))])
def test_wrong_identity_ranges_hashes_and_boolean_numbers_refuse(exported,field,value):
    folder,request=exported;request[field]=value
    with pytest.raises((ValueError,OSError)):
        GraphicCue(folder/'revision.json',request).inspect(24/C.FPS)


def test_symlink_artifact_cannot_follow_an_identical_replacement(exported,tmp_path):
    folder,request=exported;image=folder/'frame-first.png';replacement=tmp_path/'same-pixels.png';shutil.copyfile(image,replacement)
    image.unlink();image.symlink_to(replacement)
    with pytest.raises((ValueError,OSError)):
        GraphicCue(folder/'revision.json',request).inspect(24/C.FPS)


def test_changed_movie_and_early_declared_input_budget_refuse(exported):
    folder,request=exported;movie=folder/'animation.mov';old=movie.read_bytes();movie.write_bytes(old+b'changed')
    with pytest.raises(ValueError): GraphicCue(folder/'revision.json',request).inspect(24/C.FPS)
    movie.write_bytes(old);manifest=json.loads((folder/'revision.json').read_text())
    manifest['files']['annotation-font.ttf']['byteCount']=400*1024**2
    write_manifest(folder,manifest,request)
    with pytest.raises(ValueError,match='budget'): GraphicCue(folder/'revision.json',request).inspect(24/C.FPS)


def test_mutating_graphic_during_render_never_publishes_success_recipe(tmp_path,exported,monkeypatch):
    folder,request=exported;source,timeline=parent(tmp_path);before=D.sha(source),D.sha(timeline)
    original=D.render
    def mutate(*args,**kwargs):
        result=original(*args,**kwargs)
        (folder/'scene.json').write_text('replaced during composition')
        return result
    monkeypatch.setattr(D,'render',mutate)
    with pytest.raises(ValueError):
        D.derive(timeline,tmp_path/'changed',aspect='16:9',resolution='720p',graphic=GraphicCue(folder/'revision.json',request))
    assert not (tmp_path/'changed/derivative.json').exists()
    assert json.loads((tmp_path/'changed/failed.json').read_text())['state']=='failed'
    assert before==(D.sha(source),D.sha(timeline))


def test_duplicate_nonfinite_and_unsafe_leaf_metadata_refuse(tmp_path):
    for text in ['{"at":0,"at":1}','{"at":NaN}']:
        with pytest.raises(ValueError): strict_json(text)
    with pytest.raises(ValueError): fingerprint(tmp_path,'../escape',1)
