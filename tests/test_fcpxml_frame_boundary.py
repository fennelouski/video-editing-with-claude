"""Regression for duplicate connections seen in the real pizza handoff."""
import pytest
import config as C
import fcpxml as FX

@pytest.mark.parametrize('roundoff',[0,-1e-10,1e-10])
def test_shared_frame_boundary_owns_connection_and_chapter_once(tmp_path,monkeypatch,roundoff):
    source=tmp_path/'metadata-fixture.txt';source.write_text('No media in this regression fixture')
    monkeypatch.setattr(FX,'probe',lambda _: {'has_video':True,'has_audio':False,'width':1920,'height':1080,'duration':1000,'frame_duration':C.FRAME_DURATION})
    # These represent the same adjoining frame, but the first float sum is greater.
    first=440.7319583333333;duration=2.2939583333333333;next_start=443.0259166666666
    clips=[FX.Clip(source,first,6.7984583333333335,duration,name='before'),FX.Clip(source,next_start,9.426083333333333,1,name='after')]
    cue=next_start+roundoff
    graphic=FX.Connected(source,cue,0.5,name='shared-boundary',video_only=True)
    tree=FX.FCPXMLBuilder('boundary regression').build(clips,[graphic],[(cue,'shared chapter')])
    parents=tree.getroot().findall('.//spine/asset-clip')
    assert len(parents[0].findall('video'))==0
    assert len(parents[1].findall('video'))==1
    assert sum(len(p.findall('chapter-marker')) for p in parents)==1
    attached=parents[1].find('video')
    def value(s):
        if s=='0s':return 0
        n,d=s[:-1].split('/');return int(n)/int(d)
    actual=value(parents[1].get('offset'))+value(attached.get('offset'))-value(parents[1].get('start'))
    assert C.frames(actual)==C.frames(cue)


def test_positive_subframe_clip_keeps_its_serialized_one_frame_attachments(tmp_path,monkeypatch):
    source=tmp_path/'metadata-fixture.txt';source.write_text('No media in this fixture')
    monkeypatch.setattr(FX,'probe',lambda _: {'has_video':True,'has_audio':False,'width':1920,'height':1080,'duration':1000,'frame_duration':C.FRAME_DURATION})
    clip=FX.Clip(source,0,10,.01,name='subframe',markers=[(0,'start marker',True)])
    connected=FX.Connected(source,0,.01,name='start graphic',video_only=True)
    tree=FX.FCPXMLBuilder('subframe regression').build([clip],[connected],[(0,'start chapter')])
    parent=tree.getroot().find('.//spine/asset-clip')
    assert parent.get('duration')==C.FRAME_DURATION
    assert len(parent.findall('video'))==1
    assert len(parent.findall('marker'))==1
    assert len(parent.findall('chapter-marker'))==1


def test_stage5_boundary_todo_marker_survives_handoff(tmp_path,monkeypatch):
    import stage5_composite as S5
    source=tmp_path/'metadata-fixture.txt';source.write_text('No media in this fixture')
    monkeypatch.setattr(FX,'probe',lambda _: {'has_video':True,'has_audio':False,'width':1920,'height':1080,'duration':1000,'frame_duration':C.FRAME_DURATION})
    first=437.97920833333336;duration=.04170833333333333;boundary=438.02091666666666
    clips=[FX.Clip(source,first,0,duration,name='before'),FX.Clip(source,boundary,1,1,name='after')]
    assert S5._attach_todo_marker(clips,boundary,'Place this macro shot')
    assert clips[0].markers==[]
    assert len(clips[1].markers)==1
    tree=FX.FCPXMLBuilder('marker regression').build(clips,[])
    parents=tree.getroot().findall('.//spine/asset-clip')
    assert len(parents[0].findall('marker'))==0
    assert len(parents[1].findall('marker'))==1


def test_stage5_todo_marker_at_real_one_frame_boundary_survives_handoff(tmp_path,monkeypatch):
    import stage5_composite as composite
    source=tmp_path/'metadata-fixture.txt';source.write_text('No media in this fixture')
    monkeypatch.setattr(FX,'probe',lambda _: {'has_video':True,'has_audio':False,'width':1920,'height':1080,'duration':1000,'frame_duration':C.FRAME_DURATION})
    before=FX.Clip(source,437.97920833333336,10,1001/24000,name='before')
    boundary=438.02091666666666
    after=FX.Clip(source,boundary,20,1,name='after')
    assert before.offset+before.duration>boundary  # Old float caller chose the wrong parent.
    assert composite._attach_todo_marker([before,after],boundary,'BROLL: boundary action')
    assert before.markers==[]
    assert after.markers==[(boundary,'BROLL: boundary action',True)]
    tree=FX.FCPXMLBuilder('stage5 marker regression').build([before,after],[])
    parents=tree.getroot().findall('.//spine/asset-clip')
    assert len(parents[0].findall('marker'))==0
    assert len(parents[1].findall('marker'))==1
