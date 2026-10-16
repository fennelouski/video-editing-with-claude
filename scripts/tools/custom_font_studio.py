"""Project-custom font compiler. Separate from the scan-only HerMarker rules.

All sources are local immutable job inputs. No download, model, credential or font
installation is performed. Supplied/edited/generated glyph provenance stays explicit.
"""
from __future__ import annotations
import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata

import numpy as np
from PIL import Image, ImageOps
from fontTools.fontBuilder import FontBuilder
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import Glyph, GlyphCoordinates
from fontTools.ttLib.tables import ttProgram
from fontTools.varLib.instancer import instantiateVariableFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import trace as tracing

MAX_PIXELS = 32_000_000
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
sha = lambda value: hashlib.sha256(value).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pairs_unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key")
        result[key] = value
    return result


def finite(value, low, high):
    require(type(value) in (int, float) and math.isfinite(value) and low <= value <= high,
            "A numeric font parameter is outside its supported range")
    return value


def read_owned(root: Path, filename: str, expected: str, limit=64*1024*1024):
    require(re.fullmatch(r"[A-Za-z0-9_-]+\.(image|ttf|txt)", filename) is not None, "Invalid source filename")
    require(re.fullmatch("[0-9a-f]{64}", expected) is not None, "Invalid source hash")
    fd = os.open(root / filename, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= limit, "Source is empty or oversized")
        data = bytearray()
        while chunk := os.read(fd, min(1024*1024, limit+1-len(data))):
            data.extend(chunk)
            require(len(data) <= limit, "Source exceeds its byte limit")
        after = os.fstat(fd)
        require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) ==
                (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns), "Source changed while reading")
        require(sha(data) == expected, "Source hash changed")
        return bytes(data)
    finally:
        os.close(fd)


def scalar(value):
    require(type(value) is int and 0x20 <= value <= 0x10FFFF and not 0xD800 <= value <= 0xDFFF and unicodedata.category(chr(value)) not in ("Cc","Cs"),
            "Map one printable Unicode scalar per glyph")
    return value


def validate_outline(outline):
    require(isinstance(outline,dict), "An outline needs contours and an advance")
    advance = finite(outline.get("advance"), 0, 4000)
    contours = outline.get("contours")
    require(isinstance(contours,list) and len(contours) <= 256, "Too many contours")
    require(sum(len(c) for c in contours if isinstance(c,list)) <= 32768, "Too many outline points")
    for contour in contours:
        require(isinstance(contour,list) and 3 <= len(contour) <= 8192, "A contour needs at least three points")
        for point in contour:
            require(isinstance(point,dict) and type(point.get("on_curve")) is bool, "Each point needs an on-curve flag")
            finite(point.get("x"), -4000, 4000); finite(point.get("y"), -4000, 4000)
    return {"advance":round(advance),"contours":contours}


def trace_glyph(root, spec):
    scalar(spec["scalar"])
    image_bytes = read_owned(root,spec["source_file"],spec["source_sha256"])
    if spec.get("raster_file") is not None:
        image_bytes = read_owned(root,spec["raster_file"],spec["raster_sha256"],limit=256*1024*1024)
    with Image.open(io.BytesIO(image_bytes)) as original:
        require(getattr(original,"n_frames",1)==1, "Choose a still image")
        require(0 < original.width*original.height <= MAX_PIXELS, "Image is too large")
        image = ImageOps.exif_transpose(original).convert("RGBA")
        white = Image.new("RGBA",image.size,"white"); white.alpha_composite(image)
        gray = np.asarray(white.convert("L"),dtype=np.float64)/255
    crop = spec.get("crop",[0,0,1,1]); require(isinstance(crop,list) and len(crop)==4,"Choose a crop")
    x,y,w,h = [finite(v,0,1) for v in crop]
    require(w>0 and h>0 and x+w<=1+1e-12 and y+h<=1+1e-12,"Crop falls outside the oriented image")
    x0,y0 = math.floor(x*gray.shape[1]),math.floor(y*gray.shape[0])
    x1,y1 = math.ceil((x+w)*gray.shape[1]),math.ceil((y+h)*gray.shape[0])
    cell = gray[y0:y1,x0:x1]
    require(cell.size>0,"The crop is empty")
    threshold = finite(spec.get("ink_threshold",.55),.01,.99)
    ink = cell < threshold
    require(ink.any() and not ink.all(),"The selected cell needs ink and background")
    baseline = finite(spec.get("baseline",.8),0,1)
    side = finite(spec.get("sidebearing",55),0,500)
    scale = 1000/cell.shape[0]
    tolerance = finite(spec.get("tolerance_units",1.5),0,20)
    contours = tracing.trace(ink,tolerance=tolerance/scale)
    require(contours,"No usable outline was found")
    left = min(x for contour in contours for x,y in contour)
    converted = [[{"x":round((x-left)*scale+side),"y":round((baseline*cell.shape[0]-y)*scale),"on_curve":True}
                  for x,y in contour] for contour in contours]
    advance = spec.get("advance")
    if advance is None: advance = max(p["x"] for c in converted for p in c)+side
    outline = validate_outline({"advance":advance,"contours":converted})
    return {"schema_version":1,"scalar":spec["scalar"],"origin":"supplied_image","source_sha256":spec["source_sha256"],
            "source_file":spec["source_file"],"raster_file":spec.get("raster_file"),"raster_sha256":spec.get("raster_sha256"),"crop":crop,"baseline":baseline,"ink_threshold":threshold,
            "tolerance_units":tolerance,"sidebearing":side,"outline":outline,"outline_sha256":sha(canonical(outline))}


def fallback_glyph(root,spec):
    code = scalar(spec["scalar"])
    data = read_owned(root,"fallback.ttf",spec["font_sha256"])
    license_bytes = read_owned(root,"fallback-license.txt",spec["license_sha256"],limit=64*1024)
    require(b"SIL OPEN FONT LICENSE" in license_bytes,"The fallback needs its OFL license")
    font = TTFont(io.BytesIO(data),recalcTimestamp=False)
    if "fvar" in font:
        font = instantiateVariableFont(font,{axis.axisTag:axis.defaultValue for axis in font["fvar"].axes},inplace=False)
    require("Work Sans" in (font["name"].getDebugName(1) or ""),"The bundled fallback identity is not Work Sans")
    require("glyf" in font,"The bundled fallback needs TrueType outlines")
    cmap = font.getBestCmap(); require(code in cmap,"This character is not in the licensed fallback")
    name = cmap[code]; glyph = font["glyf"][name]
    coordinates,endpoints,flags = glyph.getCoordinates(font["glyf"])
    scale = 1000/font["head"].unitsPerEm
    contours = []; start = 0
    for end in endpoints:
        contours.append([{"x":round(coordinates[i][0]*scale),"y":round(coordinates[i][1]*scale),"on_curve":bool(flags[i]&1)} for i in range(start,end+1)])
        start = end+1
    outline = validate_outline({"advance":round(font["hmtx"][name][0]*scale),"contours":contours})
    return {"schema_version":1,"scalar":code,"origin":"generated_fallback","source_file":"fallback.ttf","source_sha256":spec["font_sha256"],
            "license_sha256":spec["license_sha256"],"generation":"Licensed Work Sans outline substitution; not a supplied scan or inferred handwriting",
            "outline":outline,"outline_sha256":sha(canonical(outline))}


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True,allow_nan=False).encode()


def ttf_glyph(outline):
    glyph = Glyph(); contours = outline["contours"]; glyph.numberOfContours = len(contours)
    glyph.coordinates = GlyphCoordinates([(round(p["x"]),round(p["y"])) for c in contours for p in c])
    glyph.flags = bytearray(1 if p["on_curve"] else 0 for c in contours for p in c)
    glyph.endPtsOfContours = []; offset = 0
    for contour in contours:
        offset += len(contour); glyph.endPtsOfContours.append(offset-1)
    glyph.program = ttProgram.Program(); glyph.program.fromBytecode([])
    return glyph


def compile_font(spec, root):
    family = spec.get("family")
    require(isinstance(family,str) and re.fullmatch(r"Clauto Custom [A-Za-z0-9 -]{1,64}",family),"Choose a distinct Clauto Custom family name")
    entries = spec.get("glyphs")
    require(isinstance(entries,list) and 1 <= len(entries) <= 1024,"Choose 1 to 1024 glyph mappings")
    order = [".notdef"]; cmap = {}
    box = [[{"x":x,"y":y,"on_curve":True} for x,y in contour] for contour in
           [[(50,0),(50,700),(450,700),(450,0)],[(100,50),(400,50),(400,650),(100,650)]]]
    glyphs = {".notdef":ttf_glyph({"advance":500,"contours":box})}; metrics = {".notdef":(500,50)}
    origins = []; minimum = 0; maximum = 800
    for entry in entries:
        code = scalar(entry["scalar"]); require(code not in cmap,"A character is mapped twice")
        origin = entry.get("origin"); require(origin in ("supplied_image","edited_outline","generated_fallback"),"A glyph needs explicit provenance")
        require(re.fullmatch("[0-9a-f]{64}",entry.get("source_sha256","")),"A glyph needs its source hash")
        source_name = entry.get("source_file","")
        read_owned(root,source_name,entry["source_sha256"])
        if entry.get("raster_file") is not None:
            read_owned(root,entry["raster_file"],entry["raster_sha256"],limit=256*1024*1024)
        if source_name.endswith(".ttf"):
            license_bytes = read_owned(root,"fallback-license.txt",entry.get("license_sha256",""),limit=64*1024)
            require(b"SIL OPEN FONT LICENSE" in license_bytes,"The fallback needs its license")
        else:
            require(source_name.endswith(".image") and origin != "generated_fallback","A supplied glyph needs its original image")
        outline = validate_outline(entry["outline"])
        require(sha(canonical(outline))==entry.get("outline_sha256"),"An outline changed without a new revision/hash")
        name = f"u{code:06X}"; cmap[code]=name; order.append(name); glyphs[name]=ttf_glyph(outline)
        points = [p for contour in outline["contours"] for p in contour]
        metrics[name]=(outline["advance"],min((round(p["x"]) for p in points),default=0))
        minimum=min(minimum,min((round(p["y"]) for p in points),default=0)); maximum=max(maximum,max((round(p["y"]) for p in points),default=800))
        origins.append({"scalar":code,"origin":origin,"source_sha256":entry["source_sha256"],"outline_sha256":entry["outline_sha256"],"license_sha256":entry.get("license_sha256"),"raster_sha256":entry.get("raster_sha256")})
    ascent=max(800,maximum+50); descent=min(-200,minimum-50)
    fb=FontBuilder(1000,isTTF=True);fb.setupGlyphOrder(order);fb.setupCharacterMap(cmap);fb.setupGlyf(glyphs);fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ascent,descent=descent,lineGap=120)
    fb.setupNameTable({"familyName":family,"styleName":"Regular","uniqueFontIdentifier":family+";"+sha(canonical(spec))[:24],"fullName":family,"psName":family.replace(" ",""),"version":"Version 1.000"})
    fb.setupOS2(sTypoAscender=ascent,sTypoDescender=descent,usWinAscent=ascent,usWinDescent=-descent,fsType=0)
    fb.setupPost(isFixedPitch=0);fb.font["head"].created=fb.font["head"].modified=2082844800
    ttf=io.BytesIO();fb.font.save(ttf);fb.font.flavor="woff2";woff=io.BytesIO();fb.font.save(woff)
    ttf_bytes=ttf.getvalue();woff_bytes=woff.getvalue()
    require(len(ttf_bytes)<=32*1024*1024 and len(woff_bytes)<=32*1024*1024,"The compiled font is too large")
    for data in [ttf_bytes,woff_bytes]:
        check=TTFont(io.BytesIO(data),recalcTimestamp=False);require(check.getBestCmap()==cmap,"The font mapping did not survive encoding")
    return ttf_bytes,woff_bytes,{"schema_version":1,"family":family,"units_per_em":1000,"ascender":ascent,"descender":descent,"glyphs":origins,
                               "ttf_sha256":sha(ttf_bytes),"woff2_sha256":sha(woff_bytes),"request_sha256":sha(canonical(spec))}


def main():
    parser=argparse.ArgumentParser();parser.add_argument("action",choices=["trace","fallback","build"]);parser.add_argument("request",type=Path);parser.add_argument("output",type=Path)
    args=parser.parse_args();require(args.request.is_file() and args.request.stat().st_size<=16*1024*1024,"Invalid font request")
    request_bytes=args.request.read_bytes()
    spec=json.loads(request_bytes,object_pairs_hook=pairs_unique,parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
    require(spec.get("schema_version")==1,"Unsupported font request")
    root=args.request.parent
    outputs={}
    if args.action=="trace":outputs["glyph.json"]=canonical(trace_glyph(root,spec))+b"\n"
    elif args.action=="fallback":outputs["glyph.json"]=canonical(fallback_glyph(root,spec))+b"\n";outputs["OFL.txt"]=read_owned(root,"fallback-license.txt",spec["license_sha256"],limit=64*1024)
    else:
        ttf,woff,manifest=compile_font(spec,root);manifest["input_request_sha256"]=sha(request_bytes);outputs={"font.ttf":ttf,"font.woff2":woff,"manifest.json":canonical(manifest)+b"\n"}
        licensed = [entry for entry in spec["glyphs"] if entry.get("source_file","").endswith(".ttf")]
        if licensed:
            require(len({e.get("license_sha256") for e in licensed})==1,"Mixed fallback licenses need separate font revisions")
            outputs["OFL.txt"]=read_owned(root,"fallback-license.txt",licensed[0]["license_sha256"],limit=64*1024)
    args.output.mkdir(exist_ok=False)
    for name,data in outputs.items():
        with (args.output/name).open("xb") as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
    print(json.dumps({"ok":True,"outputs":{name:sha(data) for name,data in outputs.items()}}))

if __name__=="__main__":
    try:main()
    except (ValueError,KeyError,OSError) as error:
        print(json.dumps({"ok":False,"message":str(error)}),file=sys.stderr);sys.exit(1)
