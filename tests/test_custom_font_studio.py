"""Real local font outputs; all images and text here are synthetic."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile

import numpy as np
from PIL import Image,ImageDraw,ImageFont
import pytest
import uharfbuzz as hb
from fontTools.ttLib import TTFont

REPO=Path(__file__).resolve().parents[1]
module_spec=importlib.util.spec_from_file_location("custom_font_studio",REPO/"scripts/tools/custom_font_studio.py")
F=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(F)


def image_source(root):
    image=Image.new("RGB",(100,120),"white");draw=ImageDraw.Draw(image)
    draw.ellipse((15,10,85,105),fill="black");draw.ellipse((35,30,65,85),fill="white")
    output=io.BytesIO();image.save(output,format="PNG");data=output.getvalue();(root/"source.image").write_bytes(data)
    return {"scalar":ord("O"),"source_file":"source.image","source_sha256":F.sha(data)}


def fallback(root, scalar=ord("A")):
    font=(REPO/"Clauto Editor/Clauto Editor/Resources/ClautoWorkSans.ttf").read_bytes()
    license_bytes=(REPO/"Clauto Editor/Clauto Editor/Resources/WorkSans-OFL.txt").read_bytes()
    (root/"fallback.ttf").write_bytes(font);(root/"fallback-license.txt").write_bytes(license_bytes)
    return F.fallback_glyph(root,{"scalar":scalar,"font_sha256":F.sha(font),"license_sha256":F.sha(license_bytes)})


def build(root, glyphs):
    return F.compile_font({"schema_version":1,"family":"Clauto Custom Synthetic 001","glyphs":glyphs},root)


def test_supplied_counter_trace_has_opposite_winding_and_real_ttf_woff2_output(tmp_path):
    traced=F.trace_glyph(tmp_path,image_source(tmp_path))
    assert traced["origin"]=="supplied_image" and len(traced["outline"]["contours"])==2
    def area(c):return sum(a["x"]*b["y"]-b["x"]*a["y"] for a,b in zip(c,c[1:]+c[:1]))
    contours=traced["outline"]["contours"];assert area(contours[0])*area(contours[1])<0
    ttf,woff,manifest=build(tmp_path,[traced]);assert ttf[:4]==b"\x00\x01\x00\x00" and woff[:4]==b"wOF2"
    assert manifest["glyphs"][0]["source_sha256"]==traced["source_sha256"]
    font=TTFont(io.BytesIO(ttf));assert font.getBestCmap()=={ord("O"):"u00004F"}
    target=tmp_path/"font.ttf";target.write_bytes(ttf)
    rendered=Image.new("L",(220,240),0);draw=ImageDraw.Draw(rendered);draw.text((10,0),"O",font=ImageFont.truetype(str(target),200),fill=255)
    mask=np.asarray(rendered);ys,xs=np.nonzero(mask);assert len(xs)>0
    center=(int((xs.min()+xs.max())/2),int((ys.min()+ys.max())/2));assert mask[center[1],center[0]]==0
    assert TTFont(io.BytesIO(woff)).getBestCmap()==font.getBestCmap()


def test_missing_glyph_is_visibly_marked_licensed_fallback_and_real_shaping_works(tmp_path):
    a=fallback(tmp_path);curved=fallback(tmp_path,ord("S"));space=fallback(tmp_path,ord(" "));o=F.trace_glyph(tmp_path,image_source(tmp_path))
    assert a["origin"]=="generated_fallback" and "not a supplied scan" in a["generation"]
    assert any(not p["on_curve"] for c in curved["outline"]["contours"] for p in c)
    ttf,woff,manifest=build(tmp_path,[a,curved,space,o]);face=hb.Face(ttf);font=hb.Font(face);hb.ot_font_set_funcs(font)
    buffer=hb.Buffer();buffer.add_str("A O A");buffer.guess_segment_properties();hb.shape(font,buffer)
    assert len(buffer.glyph_infos)==5 and all(i.codepoint>0 for i in buffer.glyph_infos)
    assert all(p.x_advance>0 for p in buffer.glyph_positions)
    assert manifest["glyphs"][0]["origin"]=="generated_fallback" and manifest["glyphs"][0]["license_sha256"]==a["license_sha256"]


def test_edit_and_replacement_are_different_bytes_and_old_cut_font_remains_immutable(tmp_path):
    original=F.trace_glyph(tmp_path,image_source(tmp_path));first=build(tmp_path,[original])[0];cut=tmp_path/"old-cut.ttf";cut.write_bytes(first)
    edited=json.loads(json.dumps(original));edited["origin"]="edited_outline";edited["outline"]["contours"][0][0]["x"]+=8;edited["outline_sha256"]=F.sha(F.canonical(edited["outline"]))
    second=build(tmp_path,[edited])[0];assert second!=first and cut.read_bytes()==first
    pixels=Image.open(tmp_path/"source.image").convert("RGB");ImageDraw.Draw(pixels).rectangle((10,100,90,108),fill="black");pixels.save(tmp_path/"replacement.image",format="PNG")
    spec={"scalar":ord("O"),"source_file":"replacement.image","source_sha256":F.sha((tmp_path/"replacement.image").read_bytes())}
    replacement=F.trace_glyph(tmp_path,spec);third=build(tmp_path,[replacement])[0];assert third!=second and replacement["source_sha256"]!=original["source_sha256"] and cut.read_bytes()==first


def test_invalid_mapping_tampered_source_and_nonfinite_outline_are_refused(tmp_path):
    original=F.trace_glyph(tmp_path,image_source(tmp_path))
    with pytest.raises(ValueError):build(tmp_path,[original,original])
    changed=json.loads(json.dumps(original));changed["outline"]["contours"][0][0]["x"]=float("nan")
    with pytest.raises(ValueError):build(tmp_path,[changed])
    (tmp_path/"source.image").write_bytes(b"replaced")
    with pytest.raises(ValueError):build(tmp_path,[original])
    with pytest.raises(ValueError):F.scalar(0xD800)
    with pytest.raises(ValueError):F.read_owned(tmp_path,"../outside.image","0"*64)


def test_deterministic_output_and_source_pixels_never_change(tmp_path):
    spec=image_source(tmp_path);original=(tmp_path/"source.image").read_bytes();glyph=F.trace_glyph(tmp_path,spec)
    first=build(tmp_path,[glyph]);second=build(tmp_path,[glyph])
    assert first==second and (tmp_path/"source.image").read_bytes()==original


def test_cli_outputs_include_fallback_license_and_refuse_replacing_old_files(tmp_path):
    import subprocess
    a=fallback(tmp_path);o=F.trace_glyph(tmp_path,image_source(tmp_path))
    request={"schema_version":1,"family":"Clauto Custom CLI 002","glyphs":[a,o]}
    request_file=tmp_path/"request.json";request_file.write_text(json.dumps(request))
    output=tmp_path/"outputs"
    command=[sys.executable,str(REPO/"scripts/tools/custom_font_studio.py"),"build",str(request_file),str(output)]
    result=subprocess.run(command,capture_output=True,text=True,timeout=30)
    assert result.returncode==0,result.stderr
    report=json.loads(result.stdout);assert report["ok"]
    assert (output/"OFL.txt").read_bytes()==(tmp_path/"fallback-license.txt").read_bytes()
    old={p.name:p.read_bytes() for p in output.iterdir()}
    assert json.loads(old["manifest.json"])["input_request_sha256"]==F.sha(request_file.read_bytes())
    second=subprocess.run(command,capture_output=True,text=True,timeout=30)
    assert second.returncode!=0 and {p.name:p.read_bytes() for p in output.iterdir()}==old
    assert report["outputs"]["font.ttf"]==F.sha(old["font.ttf"])


def test_cli_duplicate_keys_and_unsupported_schema_never_create_outputs(tmp_path):
    import subprocess
    request_file=tmp_path/"request.json";output=tmp_path/"outputs"
    for raw in ['{"schema_version":1,"schema_version":2}','{"schema_version":8}']:
        request_file.write_text(raw)
        result=subprocess.run([sys.executable,str(REPO/"scripts/tools/custom_font_studio.py"),"trace",str(request_file),str(output)],capture_output=True,text=True,timeout=30)
        assert result.returncode!=0 and not output.exists()


def test_canonical_working_image_is_bound_alongside_original_and_tampering_is_refused(tmp_path):
    spec=image_source(tmp_path)
    with Image.open(tmp_path/"source.image") as image:
        target=io.BytesIO();image.convert("RGBA").save(target,format="PNG")
    data=target.getvalue();(tmp_path/"working.image").write_bytes(data)
    spec.update(raster_file="working.image",raster_sha256=F.sha(data))
    glyph=F.trace_glyph(tmp_path,spec)
    ttf,_,manifest=build(tmp_path,[glyph])
    assert ttf[:4]==b"\x00\x01\x00\x00" and manifest["glyphs"][0]["raster_sha256"]==F.sha(data)
    assert glyph["source_sha256"]==spec["source_sha256"] and glyph["raster_sha256"]==F.sha(data)
    (tmp_path/"working.image").write_bytes(b"changed")
    with pytest.raises(ValueError):F.trace_glyph(tmp_path,spec)
    with pytest.raises(ValueError):build(tmp_path,[glyph])


def test_control_characters_are_not_accepted_as_printable_mappings():
    for code in (0,10,31,127,128,159,0xD800):
        with pytest.raises(ValueError):F.scalar(code)
    assert F.scalar(ord("é"))==ord("é") and F.scalar(ord(" "))==32
