import numpy as np
from tools.camera_sync_audit import normalized_matches, consistent_anchor_candidates


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


def anchor(start, offset, score=.4, runner=.12, length=10):
    return {'a_start':start,'query_seconds':length,'candidates':[
        {'score':score,'b_minus_a':offset},{'score':runner,'b_minus_a':offset+100}]}


def test_moderate_cross_microphone_peaks_need_independent_offset_agreement():
    result=consistent_anchor_candidates([anchor(4,4.598),anchor(180,4.605,.377),anchor(360,4.599,.433)])
    assert len(result)==1 and result[0]['independent_anchor_count']==3
    assert abs(result[0]['b_minus_a_seconds']-4.599)<1e-9
    assert result[0]['offset_spread_ms']<8
    assert result[0]['physical_sync_approved'] is False


def test_overlapping_windows_ambiguous_peaks_and_inconsistent_offsets_are_withheld():
    assert consistent_anchor_candidates([anchor(4,2),anchor(7,2)])==[]
    assert consistent_anchor_candidates([anchor(4,2,runner=.35),anchor(40,2,runner=.35)])==[]
    assert consistent_anchor_candidates([anchor(4,2),anchor(40,20)])==[]
    assert consistent_anchor_candidates([anchor(4,float('nan')),anchor(40,2)])==[]


def test_distinct_consistent_clusters_are_not_collapsed_into_one_sync_claim():
    result=consistent_anchor_candidates([anchor(4,-3),anchor(40,-3.01),anchor(80,20),anchor(120,20.01)])
    assert len(result)==2 and all(not r['physical_sync_approved'] for r in result)
