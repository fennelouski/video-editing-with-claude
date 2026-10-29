"""Offline, deterministic preparation for Clauto's native 3D demo studio.

Preparation produces an import request, never publishes a scene or renders media.
The native studio owns immutable scene revisions, Metal rendering and FCPXML.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
STUDIO = ROOT / "studio"
VERSION = "clauto-demo-prepare-1"
LIMIT = 1024 * 1024
RIG = {
    "template": "hero", "action": "rock", "yawRadians": 0.6,
    "pitchRadians": 0.45, "sweepRadians": 1.2, "seed": 1,
    "stepFrames": 2, "material": "walnutIron", "light": "warmSoft",
}
TEMPLATE_PRESETS = {
    "hero": {**RIG, "material": "sageClay"},
    "inspection": {**RIG, "template": "inspection", "action": "turntable",
                   "pitchRadians": 0.65, "sweepRadians": math.pi*2, "material": "sageClay"},
    "overhead": {**RIG, "template": "overhead", "action": "hold", "yawRadians": 0,
                 "pitchRadians": 1.25, "sweepRadians": 0, "material": "sageClay"},
}
PROVENANCE_KEYS = {
    "assetID", "name", "creator", "sourceURL", "license", "sourceSHA256",
    "modifications", "rightsStatus", "sourceFiles", "licenseText",
}


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, allow_nan=False) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"Duplicate JSON key: {key}.")
            result[key] = value
        return result
    def nonfinite(_):
        raise ValueError("Nonfinite JSON numbers are unsupported.")
    return json.loads(data, object_pairs_hook=pairs, parse_constant=nonfinite)


def read_regular(path, limit=LIMIT):
    """Read bounded local bytes without following a selected symlink."""
    path = Path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= limit:
            raise ValueError(f"Choose a nonempty regular file up to {limit} bytes: {path.name}.")
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(65536, before.st_size-len(data)))
            if not chunk:
                raise ValueError(f"Source changed while reading: {path.name}.")
            data += chunk
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError(f"Source changed while reading: {path.name}.")
        return data
    finally:
        os.close(fd)


def keys(value, expected, where):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise ValueError(f"{where} requires exactly: {', '.join(sorted(expected))}.")


def integer(value, low, high, where):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{where} must be an integer from {low} to {high}.")


def number(value, low, high, where):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f"{where} must be finite and between {low} and {high}.")


def text(value, size, where, *, empty=False):
    if not isinstance(value, str) or (not value and not empty) or len(value.encode()) > size or any(ord(c)<32 and c not in "\n\t\r" for c in value):
        raise ValueError(f"{where} needs {'bounded' if empty else 'nonempty bounded'} text.")


def sha(value, where):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError(f"{where} needs a lowercase SHA-256 digest.")


def validate_rig(rig):
    keys(rig, RIG, "rig")
    for key, choices in {"template": ("hero", "inspection", "overhead"),
                         "action": ("hold", "turntable", "rock", "reveal"),
                         "material": ("sageClay", "oatCard", "walnutIron"),
                         "light": ("warmSoft", "raking")}.items():
        if rig[key] not in choices:
            raise ValueError(f"Unknown rig {key}; choose {', '.join(choices)}.")
    number(rig["yawRadians"], -math.pi*2, math.pi*2, "yawRadians")
    number(rig["pitchRadians"], -math.pi/2, math.pi/2, "pitchRadians")
    number(rig["sweepRadians"], 0, math.pi*2, "sweepRadians")
    integer(rig["seed"], 1, 2**53-1, "seed")
    integer(rig["stepFrames"], 2, 2, "stepFrames")


def validate_request(request):
    keys(request, ("schemaVersion", "label", "model", "width", "height", "frameCount", "rig", "assumptions", "reviewNotes"), "request")
    integer(request["schemaVersion"], 1, 1, "schemaVersion")
    text(request["label"], 128, "label")
    if any(ord(c)<32 for c in request["label"]):
        raise ValueError("label must not contain control characters.")
    keys(request["model"], ("assetID", "meshSHA256"), "model")
    text(request["model"]["assetID"], 128, "assetID")
    sha(request["model"]["meshSHA256"], "meshSHA256")
    integer(request["width"], 320, 7680, "width")
    integer(request["height"], 240, 7680, "height")
    if request["width"]*request["height"] > 8_388_608:
        raise ValueError("Canvas exceeds 8,388,608 pixels.")
    integer(request["frameCount"], 2, 2880, "frameCount")
    if request["frameCount"] % 2:
        raise ValueError("frameCount must be even for complete stop-motion pairs.")
    validate_rig(request["rig"])
    if not isinstance(request["assumptions"], list) or len(request["assumptions"]) > 32:
        raise ValueError("Use at most 32 explicit assumptions.")
    for value in request["assumptions"]:
        text(value, 2048, "assumption")
    text(request["reviewNotes"], 8192, "reviewNotes", empty=True)
    return request


def validate_mesh(mesh):
    keys(mesh, ("vertices", "triangles", "spinRadiansPerSecond", "color"), "mesh")
    vertices, triangles = mesh["vertices"], mesh["triangles"]
    if not isinstance(vertices, list) or not 3 <= len(vertices) <= 20_000:
        raise ValueError("Use 3–20,000 vertices.")
    if not isinstance(triangles, list) or not 1 <= len(triangles) <= 40_000:
        raise ValueError("Use 1–40,000 triangles.")
    for point in vertices:
        keys(point, ("x", "y", "z"), "vertex")
        for value in point.values():
            number(value, -10000, 10000, "coordinate")
    for face in triangles:
        if not isinstance(face, list) or len(face)!=3 or any(type(i) is not int or not 0<=i<len(vertices) for i in face) or len(set(face))!=3:
            raise ValueError("Each triangle needs three distinct valid vertex indices.")
        a, b, c = [[vertices[i][k] for k in ("x", "y", "z")] for i in face]
        u, v = [b[i]-a[i] for i in range(3)], [c[i]-a[i] for i in range(3)]
        cross = (u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0])
        if math.sqrt(sum(i*i for i in cross)) <= 1e-10:
            raise ValueError("Mesh contains a degenerate triangle.")
    number(mesh["spinRadiansPerSecond"], -5, 5, "spinRadiansPerSecond")
    keys(mesh["color"], ("r", "g", "b", "a"), "color")
    for value in mesh["color"].values():
        number(value, 0, 1, "color component")
    if len(canonical(mesh)) > LIMIT:
        raise ValueError("Embedded mesh exceeds the native one-MiB import budget.")


def validate_provenance(value):
    keys(value, PROVENANCE_KEYS, "provenance")
    for key in ("assetID", "name", "creator", "license", "modifications"):
        text(value[key], 2048, key)
    text(value["sourceURL"], 2048, "sourceURL", empty=True)
    sha(value["sourceSHA256"], "sourceSHA256")
    if value["rightsStatus"] not in ("local-unverified", "cc0", "licensed"):
        raise ValueError("Use an explicit rightsStatus declaration.")
    text(value["licenseText"], 16*1024, "licenseText", empty=True)
    if value["rightsStatus"] in ("cc0", "licensed") and (not value["licenseText"] or not value["sourceURL"]):
        raise ValueError("Declared licensed assets require retained license text and source URL.")
    if not isinstance(value["sourceFiles"], dict) or not 1 <= len(value["sourceFiles"]) <= 16:
        raise ValueError("Pin 1–16 original/adapted source files.")
    for leaf, hashed in value["sourceFiles"].items():
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}", leaf):
            raise ValueError("Source file names must be simple relative leaves.")
        sha(hashed, "source file SHA256")


def load_model(asset_id, library=STUDIO / "models"):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,99}", asset_id):
        raise ValueError("Use a catalog assetID, never a path or URL.")
    folder = Path(library) / asset_id
    if folder.is_symlink() or Path(library).is_symlink():
        raise ValueError("Model folders must not be symlinks.")
    metadata = strict_json(read_regular(folder/"metadata.json"))
    keys(metadata, ("schemaVersion", "meshSHA256", "provenance", "normalization", "verification"), "model metadata")
    integer(metadata["schemaVersion"], 1, 1, "model schemaVersion")
    validate_provenance(metadata["provenance"])
    if metadata["provenance"]["assetID"] != asset_id:
        raise ValueError("Catalog asset identity does not match its folder.")
    for leaf, expected in metadata["provenance"]["sourceFiles"].items():
        if digest(read_regular(folder/leaf, 8*LIMIT)) != expected:
            raise ValueError(f"Model source changed: {leaf}; restore the pinned bytes or register a new model.")
    mesh_bytes = read_regular(folder/"mesh.json")
    if digest(mesh_bytes) != metadata["meshSHA256"]:
        raise ValueError("Adapted mesh digest does not match the model catalog.")
    mesh = strict_json(mesh_bytes)
    validate_mesh(mesh)
    return mesh, metadata


def adapt_gltf(path):
    """Decode the documented static glTF subset; never resolve network URIs.

    Deliberately refuse transforms, animation and compressed/skinned geometry
    instead of quietly changing a downloaded model's silhouette or placement.
    """
    path = Path(path)
    raw = read_regular(path)
    gltf = strict_json(raw)
    if not isinstance(gltf, dict):
        raise ValueError("glTF metadata must be a JSON object.")
    if not isinstance(gltf.get("asset"), dict):
        raise ValueError("glTF asset metadata must be an object declaring version2.0.")
    for container in ("nodes", "scenes", "meshes", "accessors", "bufferViews", "buffers", "images"):
        values = gltf.get(container, [])
        if not isinstance(values, list) or any(not isinstance(item, dict) for item in values):
            raise ValueError(f"glTF {container} must be an array of objects.")
    if gltf["asset"].get("version") != "2.0" or any(
            gltf.get(key) for key in ("animations", "skins", "extensionsRequired", "extensionsUsed")):
        raise ValueError("Use static, uncompressed glTF2 geometry without animation or extensions.")
    nodes = gltf.get("nodes", [])
    scenes = gltf.get("scenes", [])
    if not scenes:
        raise ValueError("The bounded adapter requires a nonempty glTF scenes array.")
    scene_index = gltf.get("scene", 0)
    integer(scene_index, 0, len(scenes)-1, "glTF default scene index")
    roots = scenes[scene_index].get("nodes")
    if len(nodes)!=1 or not isinstance(roots, list) or len(roots)!=1 or type(roots[0]) is not int or roots[0]!=0:
        raise ValueError("The bounded adapter requires one static root mesh node; bake the selected object into a separate glTF first.")
    node = nodes[0]
    if any(key in node for key in ("matrix", "translation", "rotation", "scale", "children", "skin", "weights")) or type(node.get("mesh")) is not int or node["mesh"] != 0 or len(gltf.get("meshes", [])) != 1:
        raise ValueError("Apply object transforms and export one static mesh before adapting; no transform is silently discarded.")
    primitives = gltf["meshes"][0].get("primitives", [])
    if not isinstance(primitives, list) or any(not isinstance(item, dict) for item in primitives):
        raise ValueError("glTF mesh primitives must be an array of objects.")
    source_files = {path.name: digest(raw)}
    buffers = []
    for spec in gltf.get("buffers", []):
        uri = spec.get("uri", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", uri) or uri in (".", ".."):
            raise ValueError("glTF buffers must be local simple file names; paths and network/data URIs refuse.")
        data = read_regular(path.parent/uri, 8*LIMIT)
        if len(data) != spec.get("byteLength"):
            raise ValueError("glTF buffer length differs from its declaration.")
        source_files[uri] = digest(data);buffers.append(data)
    for spec in gltf.get("images", []):
        uri = spec.get("uri", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", uri) or uri in (".", ".."):
            raise ValueError("glTF images must be local simple file names. Embedded and network references refuse.")
        source_files[uri] = digest(read_regular(path.parent/uri, 8*LIMIT))

    def accessor(index, expected_type, component_types):
        accessors, views = gltf.get("accessors", []), gltf.get("bufferViews", [])
        integer(index, 0, len(accessors)-1, "accessor index")
        value = accessors[index]
        if "sparse" in value or value.get("normalized") or value.get("type") != expected_type or value.get("componentType") not in component_types:
            raise ValueError("Use non-sparse float POSITION and unsigned integer triangle indices.")
        view_index = value.get("bufferView")
        integer(view_index, 0, len(views)-1, "buffer view index")
        view = views[view_index]
        buffer_index = view.get("buffer")
        integer(buffer_index, 0, len(buffers)-1, "buffer index")
        data = buffers[buffer_index]
        fmt = "<"+{5126:"f", 5123:"H", 5125:"I", 5121:"B"}[value["componentType"]]*(3 if expected_type=="VEC3" else 1)
        size = struct.calcsize(fmt)
        count, start, length = value.get("count"), view.get("byteOffset", 0), view.get("byteLength")
        offset, stride = value.get("byteOffset", 0), view.get("byteStride", size)
        integer(count, 1, 120_000, "accessor count")
        for val, name in ((start,"view offset"), (length,"view length"), (offset,"accessor offset"), (stride,"accessor stride")):
            integer(val, 0, 8*LIMIT, name)
        if stride < size or start+length > len(data) or offset+stride*(count-1)+size > length:
            raise ValueError("glTF accessor exceeds its pinned buffer view.")
        return [struct.unpack_from(fmt, data, start+offset+i*stride) for i in range(count)]

    vertices, triangles = [], []
    for primitive in primitives:
        if primitive.get("mode", 4)!=4 or primitive.get("targets") or primitive.get("extensions"):
            raise ValueError("Use static triangle primitives without morph targets or compression.")
        attributes = primitive.get("attributes", {})
        if not isinstance(attributes, dict):
            raise ValueError("glTF primitive attributes must be an object naming POSITION.")
        points = accessor(attributes.get("POSITION"), "VEC3", (5126,))
        indices = [row[0] for row in accessor(primitive.get("indices"), "SCALAR", (5121,5123,5125))]
        if len(indices)%3 or any(i>=len(points) for i in indices):
            raise ValueError("glTF triangle indices do not match the selected positions.")
        base = len(vertices)
        vertices.extend(dict(zip(("x", "y", "z"), p)) for p in points)
        triangles.extend([base+i for i in indices[n:n+3]] for n in range(0, len(indices), 3))
    mesh = {"vertices": vertices, "triangles": triangles, "spinRadiansPerSecond": 0,
            "color": {"r": 74/255, "g": 60/255, "b": 46/255, "a": 1}}
    validate_mesh(mesh)
    return mesh, source_files


def prepare_payload(request, library=STUDIO / "models"):
    validate_request(request)
    mesh, metadata = load_model(request["model"]["assetID"], library)
    if request["model"]["meshSHA256"] != metadata["meshSHA256"]:
        raise ValueError("Request pins an obsolete mesh. Choose the catalog revision explicitly.")
    # Verification notes are evidence about a model, not a scene parameter. A
    # later visual review must not silently give the same scene a new identity.
    identity = digest(canonical({"tool": VERSION, "request": request,
                                 "mesh": mesh, "provenance": metadata["provenance"]}))
    request_id = str(uuid.UUID(identity[:32], version=5)).upper()
    payload = {"schemaVersion": 1, "requestID": request_id,
               **{k: request[k] for k in ("label", "width", "height", "frameCount", "rig", "assumptions", "reviewNotes")},
               "mesh": mesh, "provenance": metadata["provenance"]}
    if len(canonical(payload)) > LIMIT:
        raise ValueError("Prepared request exceeds the native one-MiB import budget.")
    return identity, payload


def _artifact(folder, leaf, expected):
    """Resume only an exact prefix of these owned bytes, then publish exclusively."""
    destination, partial = folder/leaf, folder/(leaf+".partial")
    if destination.exists() or destination.is_symlink():
        if read_regular(destination, 2*LIMIT) != expected:
            raise ValueError(f"Existing {leaf} differs; choose a fresh output root. Nothing was overwritten.")
        return
    fd = os.open(partial, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > len(expected):
            raise ValueError(f"Unrecognized partial artifact: {partial.name}.")
        previous = os.read(fd, len(expected)+1)
        if not expected.startswith(previous):
            raise ValueError(f"Partial {leaf} does not match this recipe. Nothing was overwritten.")
        remaining = memoryview(expected)[len(previous):]
        while remaining:
            written = os.write(fd, remaining)
            remaining = remaining[written:]
        os.fsync(fd)
        os.link(partial, destination, follow_symlinks=False)
    finally:
        os.close(fd)
    # The hard link is complete before the owned temporary name is removed.
    partial.unlink()


def prepare(request, output, library=STUDIO / "models"):
    identity, payload = prepare_payload(request, library)
    output = Path(output).absolute()
    # Finder and tempfile return Apple's system aliases; normalize only these
    # known aliases before rejecting user-selected symlink paths.
    for alias, physical in ((Path("/var"), Path("/private/var")), (Path("/tmp"), Path("/private/tmp"))):
        if alias.is_symlink() and alias.resolve() == physical and output.is_relative_to(alias):
            output = physical/output.relative_to(alias)
    for ancestor in (output, *output.parents):
        if ancestor.is_symlink():
            raise ValueError("Preparation output and its parents must not be symlinks.")
    output.mkdir(parents=True, exist_ok=True)
    folder = output/identity
    folder.mkdir(exist_ok=True)
    if folder.is_symlink():
        raise ValueError("Preparation folder must not be a symlink.")
    fd = os.open(folder/".prepare.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        import_bytes, request_bytes = canonical(payload), canonical(request)
        _artifact(folder, "request.json", request_bytes)
        _artifact(folder, "import.json", import_bytes)
        receipt = {"schemaVersion": 1, "state": "prepared", "toolVersion": VERSION,
                   "recipeSHA256": identity, "requestID": payload["requestID"],
                   "files": {"request.json": digest(request_bytes), "import.json": digest(import_bytes)},
                   "renderVerified": False, "rightsStatus": payload["provenance"]["rightsStatus"],
                   "contract": {"frameRate": "24000/1001", "stepFrames": 2,
                                "import": "Studio > Graphics > Import demo request",
                                "export": "Native immutable scene revision: alpha MOV, endpoint PNGs, full-decode proof, FCPXML"}}
        _artifact(folder, "prepared.json", canonical(receipt))
    finally:
        os.close(fd)
    return folder


def discover(library=STUDIO / "models"):
    models = []
    for folder in sorted(Path(library).iterdir()):
        if not folder.is_dir() or folder.name.startswith("."):
            continue
        mesh, metadata = load_model(folder.name, library)
        models.append({"assetID": folder.name, "meshSHA256": metadata["meshSHA256"],
                       "name": metadata["provenance"]["name"],
                       "rightsStatus": metadata["provenance"]["rightsStatus"],
                       "vertices": len(mesh["vertices"]), "triangles": len(mesh["triangles"]),
                       "verification": metadata["verification"]})
    return {"schemaVersion": 1, "toolVersion": VERSION, "models": models,
            "templates": ["hero", "inspection", "overhead"],
            "actions": ["hold", "turntable", "rock", "reveal"],
            "materials": ["sageClay", "oatCard", "walnutIron"],
            "lights": ["warmSoft", "raking"], "rigExample": RIG,
            "templatePresets": TEMPLATE_PRESETS,
            "frameRate": "24000/1001", "stepFrames": 2,
            "requestSchema": "studio/request.schema.json", "nativeSchema": "studio/prepared.schema.json"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("discover", help="List verified local model hashes, rigs and schemas; no network.")
    adapter = sub.add_parser("adapt-gltf", help="Decode one static local glTF mesh without textures; emits JSON to stdout, no network or publication.")
    adapter.add_argument("gltf", type=Path)
    for command in ("validate", "prepare"):
        item = sub.add_parser(command)
        item.add_argument("request", type=Path)
        if command == "prepare":
            item.add_argument("--output", type=Path, required=True, help="Explicit disposable preparation root; never auto-selects project storage.")
    args = parser.parse_args(argv)
    try:
        if args.command == "discover":
            result = discover()
        elif args.command == "adapt-gltf":
            mesh, sources = adapt_gltf(args.gltf)
            result = {"mesh": mesh, "meshSHA256": digest(canonical(mesh)),
                      "sourceFiles": sources, "rightsVerified": False,
                      "modifications": "Static POSITION/index decode; source Y-up unchanged. UV textures omitted in favor of native matte palette. No real-world unit assertion."}
        else:
            request = strict_json(read_regular(args.request))
            if args.command == "validate":
                identity, payload = prepare_payload(request)
                result = {"valid": True, "recipeSHA256": identity, "requestID": payload["requestID"], "renderVerified": False}
            else:
                folder = prepare(request, args.output)
                result = {"state": "prepared", "folder": str(folder), "import": str(folder/"import.json"), "renderVerified": False}
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"Demo preparation stopped: {error}", file=sys.stderr)
        return 2
    except (KeyError, TypeError, IndexError, AttributeError, struct.error) as error:
        print(f"Demo preparation stopped: malformed or unsupported source metadata ({error}); use the documented static glTF or request schema.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
