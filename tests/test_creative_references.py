"""Synthetic checks of immutable creative inputs and an owned correction overlay."""
import hashlib
import pytest
import config as C
import corrections as CR
import roundtrip as RT
import stage6_watch as W

def test_supplied_creative_reference_never_falls_back_after_changed_bytes(tmp_path, monkeypatch):
    path = tmp_path / 'taste_principles.md'
    path.write_text('# Synthetic taste\nKeep real materials.\n')
    monkeypatch.setattr(C, '_PATH_SETTINGS', {'taste_principles':str(path), 'taste_principles_sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    assert C._creative_reference('taste_principles') == path
    path.write_text('# Changed reference\n')
    with pytest.raises(ValueError, match='missing or changed'):
        C._creative_reference('taste_principles')
    path.unlink()
    with pytest.raises(ValueError, match='missing or changed'):
        C._creative_reference('taste_principles')

def test_watch_and_roundtrip_corrections_preserve_pinned_reference_and_remain_binding(tmp_path, monkeypatch):
    guide = tmp_path / 'style_guide.md'
    original = b'# Synthetic source guide\n\n<!-- NEW ENTRIES GO DIRECTLY BELOW THIS LINE -->\n'
    guide.write_bytes(original)
    monkeypatch.setattr(C, '_PATH_SETTINGS', {'style_guide':str(guide)})
    monkeypatch.setattr(C, 'STYLE_GUIDE', guide)
    monkeypatch.setattr(C, 'BUILD', tmp_path / 'run')
    report = W.Report('synthetic', findings=[W.Finding(1,'Safe zone','fail','00:03','Synthetic text outside margin','layout')])
    assert W.append_to_style_guide(report) == 1
    assert RT.write_entries([RT.Change('graphic-moved','synthetic callout','Moved later')],'synthetic') == 1
    assert guide.read_bytes() == original
    overlay = C.correction_log_path()
    assert '[A-001]' in overlay.read_text() and '[R-001]' in overlay.read_text()
    with pytest.raises(CR.PlaceholderRule) as error:
        CR.load()
    assert set(error.value.ids) == {'A-001','R-001'}

def test_engine_owned_correction_workflow_keeps_its_existing_default(tmp_path, monkeypatch):
    guide = tmp_path / 'style_guide.md'
    monkeypatch.setattr(C, '_PATH_SETTINGS', {})
    monkeypatch.setattr(C, 'STYLE_GUIDE', guide)
    assert C.correction_log_path() == guide
