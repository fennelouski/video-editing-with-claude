import pytest
from tools.render_camera_proof import crop_filter, validate_range


def test_tight_crop_preserves_native_1080p_and_no_crop_is_explicit():
    assert crop_filter({'b_crop':[0,720,2560,1440]},3840,2160)=='crop=2560:1440:0:720,'
    assert crop_filter({},3840,2160)==''


@pytest.mark.parametrize('crop',[[0,0,1280,720],[0,1080,1920,1080],[2000,0,2560,1440],[-2,0,2560,1440],[0,0,2560,1000],[0.,0,2560,1440],'2560:1440:0:0'])
def test_crop_cannot_upscale_escape_source_or_inject_a_filter(crop):
    with pytest.raises(ValueError):crop_filter({'b_crop':crop},3840,2160)


def test_short_b_or_missing_a_audio_cannot_be_presented_as_synced():
    short={'streams':[{'codec_type':'video','duration':'1.0'}]}
    with pytest.raises(ValueError,match='exceeds'):validate_range(short,0,3)
    with pytest.raises(ValueError,match='missing'):validate_range(short,0,.5,needs_audio=True)
    complete={'streams':[{'codec_type':'video','duration':'3.1'},{'codec_type':'audio','duration':'3.0'}]}
    validate_range(complete,1,2,needs_audio=True)
    with pytest.raises(ValueError,match='exceeds'):validate_range(complete,1.1,2,needs_audio=True)
