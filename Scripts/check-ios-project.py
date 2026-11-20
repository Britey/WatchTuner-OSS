#!/usr/bin/env python3
"""Linux-safe project/inventory checks. This is not an Xcode build or Swift typecheck."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'WatchTunerIOS.xcodeproj'


def parse_openstep(text):
    # Parse the actual checked-in object graph instead of testing generator strings.
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', text)
    pos = 0

    def take(expected=None):
        nonlocal pos
        value = tokens[pos]
        pos += 1
        if expected is not None:
            assert value == expected, (value, expected)
        return value

    def value():
        if tokens[pos] == '{':
            take('{')
            result = {}
            while tokens[pos] != '}':
                key = take()
                assert key not in result, f'Duplicate object key {key}'
                take('=')
                result[key] = value()
                take(';')
            take('}')
            return result
        if tokens[pos] == '(':
            take('(')
            result = []
            while tokens[pos] != ')':
                result.append(value())
                if tokens[pos] != ')':
                    take(',')
            take(')')
            return result
        token = take()
        return json.loads(token) if token.startswith('"') else token

    result = value()
    assert pos == len(tokens), 'Unparsed project tokens'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default=shutil.which('swiftc'))
    args = parser.parse_args()
    tracked = [PROJECT / 'project.pbxproj', PROJECT / 'xcshareddata/xcschemes/WatchTunerIOS.xcscheme']
    before = {p: p.read_bytes() for p in tracked}
    watch_files = list((ROOT / 'WatchTuner.xcodeproj').rglob('*')) + list((ROOT / 'App').rglob('*'))
    watch_hashes = {p: hashlib.sha256(p.read_bytes()).digest() for p in watch_files if p.is_file()}
    subprocess.run(['python3', str(ROOT / 'Scripts/generate-ios-project.py')], check=True)
    assert all(p.read_bytes() == data for p, data in before.items()), 'iOS project needs regeneration'
    assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in watch_hashes.items()), 'iOS generator changed Watch files'
    project = parse_openstep(tracked[0].read_text())
    objects = project['objects']
    root = objects[project['rootObject']]
    assert root['isa'] == 'PBXProject'
    targets = [objects[key] for key in root['targets']]
    assert len(targets) == 1 and targets[0]['name'] == 'WatchTunerIOS'
    target = targets[0]
    assert target['productType'] == 'com.apple.product-type.application'
    references = {key: obj for key, obj in objects.items() if obj['isa'] == 'PBXFileReference'}
    for reference in references.values():
        if reference['sourceTree'] == 'SOURCE_ROOT':
            assert (ROOT / reference['path']).exists(), f'Missing source/resource {reference["path"]}'
    phases = [objects[key] for key in target['buildPhases']]
    source_phase = next(p for p in phases if p['isa'] == 'PBXSourcesBuildPhase')
    actual = [references[objects[key]['fileRef']]['path'] for key in source_phase['files']]
    expected = sorted(str(p.relative_to(ROOT)) for p in [*ROOT.glob('IOS/*.swift'), *ROOT.glob('Sources/TunerDSP/*.swift')])
    assert len(actual) == len(set(actual)) and sorted(actual) == expected, 'Incomplete/duplicate iOS source inventory'
    assert not any(path.startswith(('App/', 'UITests/')) for path in actual), 'Watch app included in iOS target'
    for key in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[key]['buildSettings']
        assert settings['SUPPORTED_PLATFORMS'] == 'iphoneos iphonesimulator'
        assert settings['IPHONEOS_DEPLOYMENT_TARGET'] == '18.0'
        assert settings['INFOPLIST_FILE'] == 'IOS/Info.plist'
        assert 'DEVELOPMENT_TEAM' not in settings
    with (ROOT / 'IOS/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    assert info['NSMicrophoneUsageDescription'].strip()
    assert 'UIBackgroundModes' not in info, 'iOS MVP is foreground-only'
    assert info['CFBundleIdentifier'] == '$(PRODUCT_BUNDLE_IDENTIFIER)'
    assert 'WKApplication' not in info and 'WKWatchOnly' not in info
    resources = next(p for p in phases if p['isa'] == 'PBXResourcesBuildPhase')
    resource_paths = {references[objects[key]['fileRef']]['path'] for key in resources['files']}
    assert {'IOS/Assets.xcassets', 'ThirdParty/Pitchy-4.1.0-LICENSE.txt'} <= resource_paths
    asset = ROOT / 'IOS/Assets.xcassets/AppIcon.appiconset'
    for image in json.loads((asset / 'Contents.json').read_text())['images']:
        png = (asset / image['filename']).read_bytes()
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        assert int.from_bytes(png[16:20], 'big') == int.from_bytes(png[20:24], 'big') == 1024
    scheme = ET.parse(tracked[1])
    for buildable in scheme.findall('.//BuildableReference'):
        assert buildable.attrib['BlueprintIdentifier'] == root['targets'][0]
        assert buildable.attrib['ReferencedContainer'] == 'container:WatchTunerIOS.xcodeproj'
    assert scheme.find('.//LaunchAction/BuildableProductRunnable') is not None
    print(f'PASS: deterministic project, {len(actual)} sources, valid object graph/paths/plist/scheme/icon/license, Watch generator isolation')
    if args.swiftc:
        subprocess.run([args.swiftc, '-frontend', '-parse', '-swift-version', '6', *[str(ROOT / p) for p in actual if p.startswith('IOS/')]], check=True)
        print('PASS: iOS Swift syntax parsed (imports and Apple API types are NOT checked)')
        with tempfile.TemporaryDirectory(prefix='watchtuner-input-') as temporary:
            environment = os.environ.copy()
            environment['CLANG_MODULE_CACHE_PATH'] = str(Path(temporary) / 'cache')
            executable = str(Path(temporary) / 'tone-input-smoke')
            subprocess.run([args.swiftc, '-O', '-swift-version', '6',
                            str(ROOT / 'IOS/ToneFrequencyInput.swift'),
                            str(ROOT / 'Sources/TunerDSP/SineOscillator.swift'),
                            str(ROOT / 'Scripts/IOSToneInputSmoke.swift'), '-o', executable],
                           env=environment, check=True)
            subprocess.run([executable], check=True)
            audio_executable = str(Path(temporary) / 'audio-lifetime-smoke')
            subprocess.run([args.swiftc, '-O', '-swift-version', '6',
                            str(ROOT / 'IOS/IOSAudioLifetime.swift'),
                            str(ROOT / 'Sources/TunerDSP/AudioLifecycle.swift'),
                            str(ROOT / 'Scripts/IOSAudioLifetimeSmoke.swift'), '-o', audio_executable],
                           env=environment, check=True)
            subprocess.run([audio_executable], check=True)
    else:
        print('SKIP: Swift syntax parse; swiftc not found')


if __name__ == '__main__':
    main()
