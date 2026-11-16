#!/usr/bin/env python3
"""Verify vendored source integrity and the standalone Theseus integration.

This does not compile Swift/Metal and does not substitute for native UI testing.
"""
import argparse
import hashlib
import json
from pathlib import Path

PIN = '71ca1c127a4e7fe3387361f160c4890dbd427f66'

def verify(root):
    vendor = root / 'Vendor/Theseus'
    provenance = json.loads((vendor / 'UPSTREAM.json').read_text())
    assert provenance['commit'] == PIN
    assert provenance['repository'] == 'https://github.com/valzevul/Theseus'
    assert provenance['license'] == 'Apache-2.0' and not provenance['modifications']
    expected = provenance['files']
    actual = {p.relative_to(vendor).as_posix() for p in vendor.rglob('*') if p.is_file()}
    assert actual == set(expected) | {'UPSTREAM.json'}, 'Unexpected or missing upstream files'
    for name, entry in expected.items():
        raw = (vendor / name).read_bytes()
        assert len(raw) == entry['bytes'] and hashlib.sha256(raw).hexdigest() == entry['sha256'], name
    swift = [p for p in expected if p.startswith('Sources/') and p.endswith('.swift')]
    metal = [p for p in expected if p.endswith('.metal')]
    assert len(swift) == 33 and len(metal) == 1
    assert 'Bundle.module' in (vendor / 'Sources/Theseus/Rendering/MetalContext.swift').read_text()
    for path in ['app/TBTheseusDock.h', 'app/TBTheseusDock.swift',
                 'app/TBTheseusMaterial.h', 'app/TBTheseusMaterial.swift',
                 'Integration/TheseusBundle.swift', 'tools/build-theseus.sh']:
        assert (root / path).is_file(), path
    material = (root / 'app/TBTheseusMaterial.swift').read_text()
    for name in ['TBTheseusSurface', 'TBTheseusSwitch', 'TBTheseusSlider']:
        assert '@objc(' + name + ')' in material
    assert 'TheseusView(configuration: .regular)' in material
    assert 'TheseusSwitch()' in material and 'TBTrackedTheseusSlider: TheseusSlider' in material
    assert 'override func cancelTracking' in material and '.touchCancel' in material
    assert 'TheseusTabBar()' in (root / 'app/TBTheseusDock.swift').read_text()
    assert 'TBTheseusDock' in (root / 'app/TBRootController.m').read_text()
    assert 'TBTheseusSurface' in (root / 'app/TBGlass.m').read_text()
    # All app-owned glass surfaces now use the shared Theseus renderer. UIKit
    # system pickers, menus, fonts, activity indicators, and text editing remain.
    old_blurs = [p.name for p in (root / 'app').glob('*.m')
                 if 'UIVisualEffectView' in p.read_text() or 'UIBlurEffect' in p.read_text()]
    assert not old_blurs, 'Unconverted app-owned glass: ' + ', '.join(old_blurs)
    for name in ['build.yml', 'build-linux.yml']:
        workflow = (root / '.github/workflows' / name).read_text()
        assert 'workflow_dispatch:' in workflow and '  push:' not in workflow and '  pull_request:' not in workflow
    assert 'only_if: "false"' in (root / '.cirrus.yml').read_text()
    dock = (root / 'app/TBTheseusDock.swift').read_text()
    assert 'TBTabAccessibilityElement' in dock and 'refreshBackdrop' in dock
    entitlements = (root / 'tools/entitlements.plist').read_text()
    assert 'com.apple.private.security.storage.MobileDocuments' in entitlements
    return {'passed': True, 'upstream_commit': PIN, 'original_files_verified': len(expected),
            'original_swift_files': len(swift), 'original_metal_files': len(metal),
            'upstream_modified': False, 'old_app_blur_layers': 0,
            'note': 'Static integrity checks only; native Swift/Metal build and device UI not executed.'}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    print(json.dumps(verify(args.root.resolve()), indent=2))
