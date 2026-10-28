import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("handwriting", Path(__file__).parents[1] / "scripts/handwriting.py")
H = importlib.util.module_from_spec(spec)
spec.loader.exec_module(H)


class HandwritingProtocolTests(unittest.TestCase):
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
