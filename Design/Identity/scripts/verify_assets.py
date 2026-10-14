#!/usr/bin/env python3
"""Validate actual PNG bytes, native catalog entries, editable SVGs, and contrast."""
import hashlib
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zlib

IDENTITY = Path(__file__).resolve().parents[1]
REPO = IDENTITY.parents[1]
APP_SET = REPO / "Clauto Editor/Clauto Editor/Assets.xcassets/AppIcon.appiconset"


def png_pixels(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {path}"
    offset, compressed = 8, bytearray()
    width = height = bit_depth = color_type = None
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        tag = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        assert zlib.crc32(tag + payload) & 0xffffffff == crc, f"PNG CRC failed: {path}"
        if tag == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            assert (bit_depth, color_type, compression, filtering, interlace) == (8, 6, 0, 0, 0), "Expected noninterlaced RGBA"
        elif tag == b"IDAT":
            compressed.extend(payload)
        offset += length + 12
    raw = zlib.decompress(compressed)
    assert len(raw) == height * (1 + width * 4), "Unexpected raster length"
    previous = bytearray(width * 4)
    rows = []
    position = 0
    for _ in range(height):
        mode = raw[position]
        position += 1
        row = bytearray(raw[position:position + width * 4])
        position += width * 4
        for x in range(len(row)):
            left = row[x - 4] if x >= 4 else 0
            above = previous[x]
            upper_left = previous[x - 4] if x >= 4 else 0
            if mode == 1:
                predictor = left
            elif mode == 2:
                predictor = above
            elif mode == 3:
                predictor = (left + above) // 2
            elif mode == 4:
                p = left + above - upper_left
                a, b, c = abs(p - left), abs(p - above), abs(p - upper_left)
                predictor = left if a <= b and a <= c else above if b <= c else upper_left
            else:
                assert mode == 0, "Unknown PNG filter"
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        rows.append(row)
        previous = row
    return width, height, rows


def luminance(hex_color):
    rgb = [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in rgb]
    return sum(value * weight for value, weight in zip(linear, [0.2126, 0.7152, 0.0722]))


def contrast(a, b):
    low, high = sorted([luminance(a), luminance(b)])
    return (high + 0.05) / (low + 0.05)


def main():
    geometry = json.loads((IDENTITY / "geometry.json").read_text())
    assert len(geometry["icons"]) == 21
    svgs = list(IDENTITY.glob("*.svg")) + list((IDENTITY / "icons").glob("*.svg"))
    assert len(svgs) == 25
    for path in svgs:
        root = ET.parse(path).getroot()
        assert root.attrib["viewBox"]
        assert any(element.tag.endswith("path") for element in root.iter())
        assert not any(element.tag.endswith("image") for element in root.iter()), "Vector source embeds raster"
        assert not any("href" in key for element in root.iter() for key in element.attrib), "Vector source links external resource"
    contents = json.loads((APP_SET / "Contents.json").read_text())
    expected = {(f"{size}x{size}", f"{scale}x") for size in [16, 32, 128, 256, 512] for scale in [1, 2]}
    actual = {(entry["size"], entry["scale"]) for entry in contents["images"]}
    assert expected == actual and len(contents["images"]) == 10
    outputs = []
    for entry in contents["images"]:
        path = APP_SET / entry["filename"]
        width, height, rows = png_pixels(path)
        expected_pixels = int(entry["size"].split("x")[0]) * int(entry["scale"][0])
        assert (width, height) == (expected_pixels, expected_pixels), path
        corners = [rows[0][3], rows[0][-1], rows[-1][3], rows[-1][-1]]
        alpha = [row[x] for row in rows for x in range(3, len(row), 4)]
        assert corners == [0, 0, 0, 0] and min(alpha) == 0 and max(alpha) == 255, "Alpha silhouette failed"
        opaque_colors = {tuple(row[x:x + 3]) for row in rows for x in range(0, len(row), 4) if row[x + 3] == 255}
        for color_name in ["viridian", "ivory", "citron"]:
            target = geometry["palette"][color_name]
            target_rgb = tuple(int(target[i:i + 2], 16) for i in (1, 3, 5))
            assert target_rgb in opaque_colors, f"{color_name} loses its silhouette at {width}px"
        outputs.append({"path": str(path.relative_to(REPO)), "pixels": [width, height], "rgba": True,
                        "corner_alpha": corners, "opaque_palette_present": ["viridian", "ivory", "citron"],
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    palette = geometry["palette"]
    pairs = [("ink", "ivory"), ("muted", "ivory"), ("ivory", "viridian"), ("citron", "viridian"), ("terracotta", "ivory")]
    ratios = {f"{a}/{b}": round(contrast(palette[a], palette[b]), 3) for a, b in pairs}
    assert all(ratio >= 4.5 for ratio in ratios.values()), ratios
    source_paths = [IDENTITY / "geometry.json", IDENTITY / "app-icon.svg", IDENTITY / "scripts/generate_identity.py",
                    IDENTITY / "scripts/render_assets.swift", REPO / "Clauto Editor/Clauto Editor/Views/ClautoIcon.swift"]
    report = {"result": "passed", "native_mac_entries": 10, "editable_svg_assets": 25, "interface_icons": 21,
              "contrast_ratios": ratios, "outputs": outputs,
              "sources": [{"path": str(path.relative_to(REPO)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in source_paths]}
    (IDENTITY / "previews/verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Passed: 10 RGBA native app icons, 25 editable SVG assets, 21 interface icons. Contrast ratios: {ratios}")


if __name__ == "__main__":
    main()
