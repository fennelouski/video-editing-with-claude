import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from clauto_review_documents import (current_version_document,
                                    decode_current_version,
                                    encode_review_document)


class ReviewDocumentTests(unittest.TestCase):
    VERSION = '9EC3AC2A-746D-4817-921F-CB8801089372'
    OTHER = '7E7E15AA-D03A-4561-A02E-4405CD23804F'

    def test_uuid_pointer_is_json_string_and_preserves_the_chosen_version(self):
        data = current_version_document(self.VERSION, [self.VERSION, self.OTHER])
        self.assertEqual(json.loads(data), self.VERSION)
        self.assertEqual(decode_current_version(data, [self.VERSION]), self.VERSION)
        self.assertTrue(data.startswith(b'"'))

    def test_exact_bare_uuid_failure_is_rejected_before_publication(self):
        with self.assertRaises(json.JSONDecodeError):
            decode_current_version(self.VERSION.encode(), [self.VERSION])

    def test_a_dangling_pointer_never_promotes_a_different_healthy_version(self):
        with self.assertRaises(ValueError):
            current_version_document(self.OTHER, [self.VERSION])

    def test_valid_json_of_the_wrong_shape_is_not_a_current_pointer(self):
        for value in [None, [], {'id': self.VERSION}, 14, True, 'not-a-uuid']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                decode_current_version(json.dumps(value).encode(), [self.VERSION])

    def test_json_metadata_and_text_notes_use_their_respective_formats(self):
        metadata = {'versionID': self.VERSION, 'productionAuthorized': False}
        self.assertEqual(json.loads(encode_review_document('inputs/import-binding.json', metadata)), metadata)
        note = '# Finished-cut transcript\nMachine words remain provisional.\n'
        self.assertEqual(encode_review_document('script/transcript.md', note), note.encode())

    def test_nonfinite_json_and_escaped_paths_are_not_emitted(self):
        for path, value in [('inputs/receipt.json', {'duration': float('nan')}),
                            ('../current.json', self.VERSION),
                            ('/cuts/current.json', self.VERSION)]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                encode_review_document(path, value)


if __name__ == '__main__':
    unittest.main()
