"""Serialize native review metadata without confusing JSON strings with text.

These helpers do not write files or select a replacement current version.
"""
import json
from pathlib import PurePosixPath
from uuid import UUID


def encode_review_document(relative_path, value):
    path = PurePosixPath(relative_path)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError('A review document must have a project-relative path')
    if path.suffix == '.json':
        # A UUID string is still a JSON document. Never emit it as bare text.
        return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                           indent=2, allow_nan=False) + '\n').encode('utf-8')
    if not isinstance(value, str):
        raise TypeError('Text documents require text; JSON values require .json')
    return value.encode('utf-8')


def decode_current_version(data, known_versions):
    value = json.loads(data)
    if not isinstance(value, str):
        raise ValueError('The native current pointer must be a JSON UUID string')
    version = str(UUID(value)).upper()
    known = {str(UUID(item)).upper() for item in known_versions}
    if version not in known:
        raise ValueError('The current pointer must name an existing saved version')
    return version


def current_version_document(version, known_versions):
    data = encode_review_document('cuts/current.json', version)
    decode_current_version(data, known_versions)
    return data
