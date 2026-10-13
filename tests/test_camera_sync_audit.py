import numpy as np
from tools.camera_sync_audit import normalized_matches


def test_waveform_match_offset_sign_gain_dc_and_polarity():
    random=np.random.default_rng(53)
    query=random.normal(0,1,12000)
    reference=random.normal(0,.05,60000)
    reference[14280:26280]=-query*2+.7
    best=normalized_matches(reference,query)[0]
    assert best['at']==7.14
    assert best['score']>.999


def test_silent_short_nonfinite_and_longer_queries_are_not_matches():
    assert normalized_matches(np.ones(8000),np.ones(3000))==[]
    assert normalized_matches(np.zeros(8000),np.arange(10))==[]
    assert normalized_matches(np.zeros(3000),np.arange(4000))==[]
    assert normalized_matches(np.full(8000,np.nan),np.arange(3000))==[]


def test_separate_repeated_take_peaks_remain_candidates():
    random=np.random.default_rng(82);query=random.normal(0,1,3000)
    reference=np.zeros(18000);reference[1000:4000]=query;reference[12000:15000]=query
    peaks=normalized_matches(reference,query,count=2)
    assert {round(x['at'],3) for x in peaks}=={.5,6.0}
    assert all(x['score']>.999 for x in peaks)
