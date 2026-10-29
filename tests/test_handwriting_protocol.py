import importlib.util
import json
import hashlib
import uuid
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("handwriting", Path(__file__).parents[1] / "scripts/handwriting.py")
H = importlib.util.module_from_spec(spec)
spec.loader.exec_module(H)


class HandwritingProtocolTests(unittest.TestCase):
    def saved_style(self, root):
        project_id, asset_id, revision_id, style_id = [str(uuid.uuid4()).upper() for _ in range(4)]
        original = b"Synthetic protocol bytes; not image artwork or user approval."
        review = {"status": "approved", "liked": True, "spellingChecked": True,
                  "alphaEdgesChecked": True, "reviewer": "Synthetic test reviewer",
                  "comments": "Warm readable short labels; test data only.",
                  "contexts": ["Protocol fixtures only"]}
        source = {"projectID": project_id, "id": asset_id, "revisionID": revision_id,
                  "exactText": "Cre\u0300me brûlée", "locale": "fr-FR", "review": review,
                  "recipe": {"frameCount": 48},
                  "provenance": {"sourceSHA256": hashlib.sha256(original).hexdigest()}}
        preset = {**{k: source[k] for k in ("exactText", "locale", "review", "recipe", "provenance")},
                  "id": style_id, "name": "Synthetic label", "sourceAssetID": asset_id,
                  "sourceRevisionID": revision_id, "sourceWidth": 64, "sourceHeight": 40}
        def write_json(path, value):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        def publish(folder, ident, files):
            folder.mkdir(parents=True, exist_ok=True)
            for name, data in files.items():
                (folder / name).write_bytes(data)
            write_json(folder / "creative-claim.json", {"schemaVersion": 1, "destination": ident,
                       "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}})
        write_json(root / "clauto-project.json", {"id": project_id})
        write_json(root / ".clauto/handwriting-styles-index.json", {"schemaVersion": 1, "projectID": project_id, "ids": [style_id]})
        write_json(root / ".clauto/handwriting-index.json", {"schemaVersion": 1, "projectID": project_id,
                   "entries": [{"assetID": asset_id, "revisionID": revision_id}]})
        source_root = root / "assets/handwriting" / asset_id / revision_id
        style_root = root / "assets/handwriting/styles" / style_id
        publish(source_root, revision_id, {"original.image": original, "document.json": json.dumps(source).encode()})
        publish(style_root, style_id, {"style.json": json.dumps(preset).encode()})
        return preset, source_root, style_root / "style.json"

    def test_saved_approved_style_drives_request_but_changed_original_refuses(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            preset, source, style = self.saved_style(root)
            self.assertEqual(H.discover(root), [preset])
            output = root / "request.json"
            self.assertEqual(H.main(["request", "--text", "Different exact text", "--locale", "en", "--project", str(root), "--approved-style", str(style), "--out", str(output)]), 0)
            request = H.load(output)
            self.assertEqual(request["sourceStyleID"], preset["id"])
            self.assertEqual(request["exactText"], "Different exact text")
            self.assertEqual(request["approval"], "draft")
            self.assertIn(preset["review"]["comments"], request["prompt"])
            (source / "original.image").write_bytes(b"Changed source bytes")
            with self.assertRaisesRegex(ValueError, "changed"):
                H.discover(root)

    def test_unindexed_revision_and_linked_style_directory_are_not_discovered(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            preset, source, style = self.saved_style(root)
            index_path = root / ".clauto/handwriting-index.json"
            index_bytes = index_path.read_bytes()
            index = H.load(index_path); index["entries"] = []
            index_path.write_text(json.dumps(index))
            with self.assertRaisesRegex(ValueError, "not an admitted"):
                H.discover(root)
            index_path.write_bytes(index_bytes)
            moved = root / "linked-style-target"
            style.parent.rename(moved)
            style.parent.symlink_to(moved, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "linked project paths"):
                H.discover(root)

    def test_invalid_request_locale_and_nonobject_json_fail_cleanly(self):
        for locale in ("fr\n", " ", "x" * 129):
            with self.assertRaises(ValueError):
                H.request("Crème brûlée", locale)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "object.json"
            for invalid in ([], None, "approved"):
                path.write_text(json.dumps(invalid))
                with self.assertRaisesRegex(ValueError, "JSON object"):
                    H.load(path)

    def test_exact_unicode_request_and_truthful_provider_boundary(self):
        exact = "Cre\u0300me brûlée\nالعربية"
        value = H.request(exact, "fr")
        self.assertEqual(value["exactText"].encode(), exact.encode())
        self.assertEqual(value["status"], "awaitingProvider")
        self.assertEqual(value["approval"], "draft")
        self.assertIn("No live provider", value["providerBoundary"])

    def test_like_and_approval_without_checks_do_not_enter_reuse(self):
        for review in ({"status": "draft", "liked": True}, {"status": "approved", "liked": True}, {"status": "rejected"}):
            with self.assertRaises(ValueError):
                H.request("Seasoning", "en", {"review": review})

    def test_standalone_style_cannot_bypass_saved_project_verification(self):
        with tempfile.TemporaryDirectory() as folder:
            style = Path(folder) / "style.json"
            style.write_text(json.dumps({"review": {"status": "approved", "liked": True}}))
            self.assertEqual(H.main(["request", "--text", "Seasoning", "--locale", "en", "--approved-style", str(style), "--out", str(Path(folder) / "request.json")]), 2)
            self.assertFalse((Path(folder) / "request.json").exists())

    def test_exclusive_request_write_preserves_existing_file(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "request.json"
            self.assertEqual(H.main(["request", "--text", "è", "--locale", "fr", "--out", str(output)]), 0)
            before = output.read_bytes()
            self.assertEqual(H.main(["request", "--text", "different", "--locale", "en", "--out", str(output)]), 2)
            self.assertEqual(output.read_bytes(), before)

    def test_ambiguous_json_nonfinite_and_unapproved_discovery_refuse(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            value = root / "input.json"
            for bad in ('{"status":"draft","status":"approved"}', '{"width":NaN}'):
                value.write_text(bad)
                with self.assertRaises(ValueError):
                    H.load(value)
            (root / "clauto-project.json").write_text(json.dumps({"id": "project"}))
            self.assertEqual(H.discover(root), [])
            (root / ".clauto").mkdir()
            (root / ".clauto/handwriting-styles-index.json").write_text(json.dumps({"schemaVersion": 1, "projectID": "wrong", "ids": []}))
            with self.assertRaises(ValueError):
                H.discover(root)


if __name__ == "__main__":
    unittest.main()
