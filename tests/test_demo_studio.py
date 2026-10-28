"""Offline studio contract and interrupted/repeated preparation invariants."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json
from pathlib import Path
import shutil

import unittest
import tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"scripts"))
import demo_studio as D

def request():
    return D.strict_json((D.STUDIO/"examples/kaykit-pan-a.json").read_bytes())


class DemoStudioTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.tmp_path = Path(self._temp.name).resolve()



    def test_discovery_reports_recorded_evidence_separately_from_preparation(self):
        result = D.discover()
        assert result["frameRate"] == "24000/1001" and result["stepFrames"] == 2
        assert {m["assetID"] for m in result["models"]} == {"kaykit-pan-a", "legacy-pan-layer"}
        pan = next(m for m in result["models"] if m["assetID"]=="kaykit-pan-a")
        assert (pan["vertices"], pan["triangles"], pan["rightsStatus"]) == (289, 310, "cc0")
        assert pan["verification"]["nativeImportVerified"] is True
        assert pan["verification"]["visualReview"] == "form-study-stills-passed"
        evidence = json.loads((D.STUDIO.parent/pan["verification"]["evidence"]).read_text())
        assert evidence["movieProof"]["decodedEveryFrame"] is True
        for name, record in evidence["retainedImages"].items():
            path = D.STUDIO.parent/Path(pan["verification"]["evidence"]).parent/name
            assert D.digest(path.read_bytes()) == record["sha256"]
        legacy = next(m for m in result["models"] if m["assetID"]=="legacy-pan-layer")
        assert legacy["verification"]["nativeImportVerified"] is False

    def test_strict_json_refuses_duplicate_or_nonfinite_values(self):
        for raw in ['{"a":1,"a":2}', '{"x":NaN}', '{"x":Infinity}']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                D.strict_json(raw)

    def test_invalid_request_cannot_prepare(self):
        changes = [
            lambda r: r.update(unrecognized="ignored?"),
            lambda r: r.update(frameCount=95),
            lambda r: r.update(frameCount=True),
            lambda r: r.update(width=7680, height=7680),
            lambda r: r["rig"].update(stepFrames=1),
            lambda r: r["rig"].update(sweepRadians=-0.1),
            lambda r: r["rig"].update(seed=2**53),
            lambda r: r["model"].update(assetID="../../other"),
            lambda r: r.update(label="bad\nlabel"),
        ]
        for index, change in enumerate(changes):
            value = request();change(value)
            with self.subTest(index=index), self.assertRaises(ValueError):
                D.prepare_payload(value)

    def test_same_inputs_produce_byte_identical_content_ids_and_imports(self):
        tmp_path = self.tmp_path
        value = request()
        one, two = D.prepare(value, tmp_path/"first"), D.prepare(value, tmp_path/"second")
        assert one.name == two.name
        for leaf in ("request.json", "import.json", "prepared.json"):
            assert (one/leaf).read_bytes() == (two/leaf).read_bytes()
        payload = D.strict_json((one/"import.json").read_bytes())
        assert payload["provenance"]["licenseText"] == (D.STUDIO/"models/kaykit-pan-a/LICENSE.txt").read_text()
        assert D.strict_json((one/"prepared.json").read_bytes())["renderVerified"] is False

    def test_repeat_prepare_keeps_original_inode_and_does_not_create_new_scene(self):
        tmp_path = self.tmp_path
        folder = D.prepare(request(), tmp_path)
        before = {p.name: p.stat().st_ino for p in folder.iterdir()}
        assert D.prepare(request(), tmp_path) == folder
        assert {p.name: p.stat().st_ino for p in folder.iterdir()} == before

    def test_interrupted_prefix_resumes_to_exact_bytes(self):
        tmp_path = self.tmp_path
        value = request();identity, payload = D.prepare_payload(value)
        folder = tmp_path/identity;folder.mkdir()
        expected = D.canonical(payload)
        (folder/"import.json.partial").write_bytes(expected[:317])
        assert D.prepare(value, tmp_path) == folder
        assert (folder/"import.json").read_bytes() == expected
        assert not (folder/"import.json.partial").exists()

    def test_foreign_partial_or_existing_artifact_refuses_without_overwriting(self):
        tmp_path = self.tmp_path
        value = request();identity, _ = D.prepare_payload(value)
        folder = tmp_path/identity;folder.mkdir()
        (folder/"import.json.partial").write_bytes(b"foreign source")
        with self.assertRaisesRegex(ValueError, "Partial"):
            D.prepare(value, tmp_path)
        assert (folder/"import.json.partial").read_bytes() == b"foreign source"
        assert not (folder/"prepared.json").exists()
        (folder/"import.json.partial").unlink()
        (folder/"import.json").write_bytes(b"different")
        with self.assertRaisesRegex(ValueError, "Nothing was overwritten"):
            D.prepare(value, tmp_path)
        assert (folder/"import.json").read_bytes() == b"different"

    def test_concurrent_repeated_preparation_serializes_one_immutable_recipe(self):
        tmp_path = self.tmp_path
        with ThreadPoolExecutor(max_workers=4) as pool:
            folders = list(pool.map(lambda _: D.prepare(request(), tmp_path), range(8)))
        assert len(set(folders)) == 1
        receipt = D.strict_json((folders[0]/"prepared.json").read_bytes())
        for leaf, expected in receipt["files"].items():
            assert D.digest((folders[0]/leaf).read_bytes()) == expected

    def test_changed_pinned_model_or_request_digest_refuses(self):
        tmp_path = self.tmp_path
        library = tmp_path/"models"
        shutil.copytree(D.STUDIO/"models/kaykit-pan-a", library/"kaykit-pan-a")
        (library/"kaykit-pan-a/pan_A.bin").write_bytes(b"substitution")
        with self.assertRaisesRegex(ValueError, "source changed"):
            D.prepare_payload(request(), library)
        value = request();value["model"]["meshSHA256"] = "0"*64
        with self.assertRaisesRegex(ValueError, "obsolete mesh"):
            D.prepare_payload(value)

    def test_symlinks_cannot_stand_in_for_selected_model_or_output(self):
        tmp_path = self.tmp_path
        linked = tmp_path/"linked";linked.symlink_to(D.STUDIO/"models", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            D.prepare_payload(request(), linked)
        actual = tmp_path/"actual";actual.mkdir()
        output = tmp_path/"output";output.symlink_to(actual, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            D.prepare(request(), output)

    def test_geometry_and_licensed_provenance_fail_closed(self):
        mesh, metadata = D.load_model("kaykit-pan-a")
        bad = deepcopy(mesh);bad["triangles"][0][0] = len(mesh["vertices"])
        with self.assertRaisesRegex(ValueError, "indices"):
            D.validate_mesh(bad)
        bad = deepcopy(mesh);bad["vertices"][bad["triangles"][0][1]] = bad["vertices"][bad["triangles"][0][0]]
        with self.assertRaisesRegex(ValueError, "degenerate"):
            D.validate_mesh(bad)
        bad = deepcopy(metadata["provenance"]);bad["licenseText"] = ""
        with self.assertRaisesRegex(ValueError, "license text"):
            D.validate_provenance(bad)

    def test_schemas_cover_actual_prepared_envelope_and_rig(self):
        source = json.loads((D.STUDIO/"request.schema.json").read_text())
        prepared = json.loads((D.STUDIO/"prepared.schema.json").read_text())
        _, payload = D.prepare_payload(request())
        assert set(source["required"]) == set(request())
        assert set(prepared["required"]) == set(payload)
        assert set(prepared["properties"]["rig"]["required"]) == set(payload["rig"])
        assert prepared["additionalProperties"] is False
        assert len(D.canonical(payload)) <= D.LIMIT

    def test_static_gltf_adapter_reproduces_catalog_mesh_exactly(self):
        mesh, files = D.adapt_gltf(D.STUDIO/"models/kaykit-pan-a/pan_A.gltf")
        retained, metadata = D.load_model("kaykit-pan-a")
        assert D.canonical(mesh) == D.canonical(retained)
        for leaf, hashed in files.items():
            assert metadata["provenance"]["sourceFiles"][leaf] == hashed

    def test_gltf_network_uri_or_unapplied_transform_refuses(self):
        folder = self.tmp_path/"pan"
        shutil.copytree(D.STUDIO/"models/kaykit-pan-a", folder)
        path = folder/"pan_A.gltf";original = json.loads(path.read_text())
        changed = deepcopy(original);changed["buffers"][0]["uri"] = "https://example.invalid/pan.bin"
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "network"):
            D.adapt_gltf(path)
        changed = deepcopy(original);changed["nodes"][0]["scale"] = [2,2,2]
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "transforms"):
            D.adapt_gltf(path)

    def test_catalog_review_notes_do_not_change_prepared_scene_identity(self):
        library = self.tmp_path/"models"
        shutil.copytree(D.STUDIO/"models/kaykit-pan-a", library/"kaykit-pan-a")
        before, before_payload = D.prepare_payload(request(), library)
        path = library/"kaykit-pan-a/metadata.json";metadata = D.strict_json(path.read_bytes())
        metadata["verification"]["visualReview"] = "Separate review received; see review artifact."
        path.write_bytes(D.canonical(metadata))
        after, after_payload = D.prepare_payload(request(), library)
        assert before == after and D.canonical(before_payload) == D.canonical(after_payload)

    def test_gltf_default_scene_index_refuses_negative_or_boolean(self):
        folder = self.tmp_path/"pan"
        shutil.copytree(D.STUDIO/"models/kaykit-pan-a", folder)
        path = folder/"pan_A.gltf";original = json.loads(path.read_text())
        for index in (-1, True, False, 1, 0.0, "0"):
            changed = deepcopy(original);changed["scene"] = index
            path.write_text(json.dumps(changed))
            with self.subTest(index=index), self.assertRaisesRegex(ValueError, "default scene index"):
                D.adapt_gltf(path)

    def test_gltf_containers_fail_with_actionable_validation_errors(self):
        folder = self.tmp_path/"pan"
        shutil.copytree(D.STUDIO/"models/kaykit-pan-a", folder)
        path = folder/"pan_A.gltf";original = json.loads(path.read_text())
        for top in ([], None, 2):
            path.write_text(json.dumps(top))
            with self.subTest(top=top), self.assertRaisesRegex(ValueError, "JSON object"):
                D.adapt_gltf(path)
        for container in ("nodes", "scenes", "meshes", "accessors", "bufferViews", "buffers", "images"):
            for invalid in ({}, None, 1, [None]):
                changed = deepcopy(original);changed[container] = invalid
                path.write_text(json.dumps(changed))
                with self.subTest(container=container, invalid=invalid), self.assertRaisesRegex(ValueError, f"{container} must be an array of objects"):
                    D.adapt_gltf(path)

if __name__ == "__main__":
    unittest.main()
