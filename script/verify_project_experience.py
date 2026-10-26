#!/usr/bin/env python3
"""Bounded checks for integrated project navigation and library improvements."""
import argparse
from pathlib import Path
import subprocess
import sys
parser = argparse.ArgumentParser()
parser.add_argument('mode', choices=['core','app','store-build','store'])
parser.add_argument('--seconds', type=int, default=180)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
suites = 'ProjectExperienceTests|ProjectCatalogTests|ProjectRestorationTests|ProjectScriptSelectionTests|GraphicStudioTests|GraphicIntegrationTests|GraphicCompositionTests|GraphicSavedCutRenderTests|StoragePlanningTests|StorageMigrationTests|StorageCacheTests|StorageSetupControllerTests'
if args.mode in ['store-build','store']:
    suites = 'ProjectExperienceNativeTests|StorageSetupNativeStoreTests|ProjectCatalogNativeStoreTests|ProjectRestorationNativeStoreTests'
raise SystemExit(subprocess.run([sys.executable,str(root/'script/verify_project_catalog.py'),args.mode,'--seconds',str(args.seconds),'--filter',suites,'--derived-data',str(root/'.artifacts/StorageDerivedData')],cwd=root).returncode)
