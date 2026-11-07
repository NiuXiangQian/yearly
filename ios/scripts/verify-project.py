#!/usr/bin/env python3
"""Check the actual Xcode project graph and packaged resources without Xcode."""
import json
import plistlib
import struct
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', str(root / 'Yearly.xcodeproj/project.pbxproj')
]))
objects = project['objects']
target = objects['F00000000000000000000040']
phases = [objects[key] for key in target['buildPhases']]
packaged = {}
for phase in phases:
    paths = [objects[objects[key]['fileRef']]['path'] for key in phase['files']]
    packaged[phase['isa']] = paths
    for path in paths:
        assert (root / 'Yearly' / path).exists(), f'Missing build input: {path}'
assert set(packaged['PBXSourcesBuildPhase']) == {p.name for p in (root / 'Yearly').glob('*.swift')}
assert {'PrivacyInfo.xcprivacy', 'Assets.xcassets'} <= set(packaged['PBXResourcesBuildPhase'])
configurations = objects[target['buildConfigurationList']]['buildConfigurations']
for key in configurations:
    settings = objects[key]['buildSettings']
    assert settings['INFOPLIST_FILE'] == 'Yearly/Info.plist'
    assert settings['ASSETCATALOG_COMPILER_APPICON_NAME'] == 'AppIcon'
    assert settings['TARGETED_DEVICE_FAMILY'] == '1'
    assert settings['GENERATE_INFOPLIST_FILE'] == 'NO'
info = plistlib.loads((root / 'Yearly/Info.plist').read_bytes())
assert not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False)
assert info['YearlyPrivacyPolicyURL'] == '$(YEARLY_PRIVACY_URL)'
manifest = plistlib.loads((root / 'Yearly/PrivacyInfo.xcprivacy').read_bytes())
assert manifest['NSPrivacyTracking'] is False
assert manifest['NSPrivacyAccessedAPITypes'][0]['NSPrivacyAccessedAPITypeReasons'] == ['CA92.1']
icons = root / 'Yearly/Assets.xcassets/AppIcon.appiconset'
for entry in json.loads((icons / 'Contents.json').read_text())['images']:
    data = (icons / entry['filename']).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    expected = int(entry['size'].split('x')[0]) * int(entry['scale'][:-1])
    assert width == height == expected
    assert color == 2, 'App icons must be RGB without transparency'
scheme = ET.parse(root / 'Yearly.xcodeproj/xcshareddata/xcschemes/Yearly.xcscheme')
assert scheme.find('ArchiveAction').attrib['buildConfiguration'] == 'Release'
print('Xcode source membership, resources, icon sizes, plist and shared scheme checks passed.')
