from xml.etree import ElementTree as ET

import pytest
import config as C
import fcpxml as FX
import stage5_composite as S5
import stepclock as SC
from PIL import Image


@pytest.mark.parametrize('aspect', ['16:9', '9:16'])
@pytest.mark.parametrize('resolution,short', [('720p',720), ('1080p',1080), ('2160p',2160)])
def test_timeline_canvas_and_caption_grid_scale_together(tmp_path, video, aspect, resolution, short):
    expected = (short * 16 // 9, short) if aspect == '16:9' else (short, short * 16 // 9)
    spec = C.canvas_spec(aspect, resolution)
    assert spec['author'] == spec['render'] == expected
    factor = short / 1080
    for key in ['margin_left', 'margin_right', 'caption_baseline', 'chrome_bottom']:
        assert spec[key] == round(C.ASPECTS[aspect][key] * factor)
    builder = FX.FCPXMLBuilder('Resolution', aspect, resolution=resolution)
    path = builder.write(builder.build([FX.Clip(video, 0, 0, 1)], []), tmp_path / 'export.fcpxml')
    fmt = ET.parse(path).find('resources/format')
    assert (int(fmt.get('width')), int(fmt.get('height'))) == expected
    assert FX.validate(path) == []
    assert FX.dtd_problems(path) in (None, [])
    ass = S5.build_ass([{'word': 'synthetic', 'start': 0, 'end': .8}], aspect, tmp_path / 'caption.ass', resolution)
    text = ass.read_text()
    assert f'PlayResX: {expected[0]}' in text and f'PlayResY: {expected[1]}' in text
    size = round(C.TYPE_SCALE['caption'][0 if aspect == '16:9' else 1] * factor)
    assert f'Style: Base,{C.FONT_TEXT},{size},' in text


def test_invalid_resolution_and_unscaled_legacy_default():
    with pytest.raises(ValueError): C.canvas_spec('16:9', '8K')
    assert C.canvas_spec('16:9', '1080p')['author'] == (1920,1080)


def test_actual_raster_layout_shadow_and_motion_are_proportional(tmp_path):
    sprite=Image.new('RGBA',(150,90),(138,154,123,255))
    boxes=[]
    pose=SC.Transform(x=12,y=-9,rotation=1.5,scale=1.02,opacity=.9)
    for resolution in ['720p','1080p','2160p']:
        spec=C.canvas_spec('16:9',resolution); factor=spec['pixel_scale']
        slots=S5.layout_slots(2,spec)
        assert (slots[1][0]-(slots[0][0]+slots[0][2]))/factor==pytest.approx(64,abs=1)
        canvas=Image.new('RGBA',spec['author'])
        for slot in slots:
            prepared,position=S5.place_sprite(sprite.copy(),slot,pose,factor)
            canvas.alpha_composite(prepared,position)
        canvas.save(tmp_path/f'{resolution}.png')
        bbox=canvas.getchannel('A').point(lambda value:255 if value>=13 else 0).getbbox()
        boxes.append(tuple(value/factor for value in bbox))
    for bbox in boxes:
        assert bbox==pytest.approx(boxes[1],abs=3)
