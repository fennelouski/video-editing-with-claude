"""Shipping identity and build entry points for the existing integrated editor."""
import json
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(sys.platform != "darwin", reason="Xcode project plist validation uses macOS plutil")
def test_script_feature_uses_the_one_existing_editor_app_target():
    project = ROOT / "Clauto Editor/Clauto Editor.xcodeproj/project.pbxproj"
    objects = json.loads(subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project)], text=True))["objects"]
    apps = [o for o in objects.values() if o.get("isa") == "PBXNativeTarget" and o.get("productType") == "com.apple.product-type.application"]
    assert len(apps) == 1
    app = apps[0]
    assert app["name"] == "Clauto Editor"
    assert objects[app["productReference"]]["path"] == "Clauto Editor.app"
    configurations = objects[app["buildConfigurationList"]]["buildConfigurations"]
    assert {objects[c]["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] for c in configurations} == {"com.nathanfennel.Clauto-Editor"}


def test_script_builder_rejects_the_retired_companion_launcher():
    script = ROOT / "script/build_script_candidate.sh"
    result = subprocess.run(["bash", str(script), "--launch-fixture", "/never-open-this-project"], capture_output=True, text=True)
    assert result.returncode == 2
    assert "--build-only" in result.stderr
    assert "Clauto Script QA.app" not in script.read_text()
    assert "PlistBuddy" not in script.read_text()
