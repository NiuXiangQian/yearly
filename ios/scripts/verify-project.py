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
source_group = objects['F00000000000000000000021']
group_children = set(source_group['children'])
packaged = {}
for phase in phases:
    if phase['isa'] == 'PBXCopyFilesBuildPhase':
        continue
    refs = [objects[key]['fileRef'] for key in phase['files']]
    paths = [objects[ref]['path'] for ref in refs]
    packaged[phase['isa']] = paths
    for ref, path in zip(refs, paths):
        assert ref in group_children, f'Build input is outside the Yearly project group: {path}'
        assert (root / source_group['path'] / path).exists(), f'Missing build input: {path}'
assert set(packaged['PBXSourcesBuildPhase']) == {p.name for p in (root / 'Yearly').glob('*.swift')}
for path in (root / 'Yearly').glob('*.swift'):
    assert 'import WebKit' not in path.read_text() and 'WKWebView' not in path.read_text(), f'Native target embeds a web shell: {path}'
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
extension = next(value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'YearlyShare')
assert extension['productType'] == 'com.apple.product-type.app-extension'
embed = next(phase for phase in phases if phase['isa'] == 'PBXCopyFilesBuildPhase')
assert embed['dstSubfolderSpec'] == '13' or embed['dstSubfolderSpec'] == 13
assert extension['productReference'] in [objects[key]['fileRef'] for key in embed['files']]
assert any(objects[key]['target'] in objects[project['rootObject']]['targets'] and
           objects[objects[key]['target']]['name'] == 'YearlyShare' for key in target['dependencies'])
for name in ('Yearly', 'YearlyShare'):
    entitlement = plistlib.loads((root / name / f'{name}.entitlements').read_bytes())
    assert entitlement['keychain-access-groups'] == ['$(AppIdentifierPrefix)$(YEARLY_APP_BUNDLE_ID)']
for key in objects[extension['buildConfigurationList']]['buildConfigurations']:
    settings = objects[key]['buildSettings']
    assert settings['APPLICATION_EXTENSION_API_ONLY'] == 'YES'
    assert settings['PRODUCT_BUNDLE_IDENTIFIER'] == '$(YEARLY_APP_BUNDLE_ID).share'
extension_info = plistlib.loads((root / 'YearlyShare/Info.plist').read_bytes())['NSExtension']
assert extension_info['NSExtensionPointIdentifier'] == 'com.apple.share-services'
assert extension_info['NSExtensionAttributes']['NSExtensionActivationRule']['NSExtensionActivationSupportsImageWithMaxCount'] == 20
print('Xcode source membership, resources, icon sizes, plist and shared scheme checks passed.')
