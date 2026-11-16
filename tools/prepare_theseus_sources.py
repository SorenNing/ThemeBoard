#!/usr/bin/env python3
"""Stage pinned optics with explicit geometry and capture presentation fixes.

Vendor and shader bytes remain upstream. Presentation patches are hashed and
isolated in the disposable build copy; lens physics and materials are unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def replace_once(text, old, new, name):
    if text.count(old) != 1:
        raise ValueError('Pinned patch anchor changed: ' + name)
    return text.replace(old, new)


def prepare(root, output):
    vendor = root / 'Vendor/Theseus'
    provenance = json.loads((vendor / 'UPSTREAM.json').read_text())
    for name, metadata in provenance['files'].items():
        raw = (vendor / name).read_bytes()
        if hashlib.sha256(raw).hexdigest() != metadata['sha256']:
            raise ValueError('Upstream integrity mismatch: ' + name)
    if output == root or output == vendor or vendor in output.parents:
        raise ValueError('Output must be a disposable build directory outside Vendor')
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    # Copy bytes only: iSH shared folders do not reliably support copystat/utime.
    for source in (vendor / 'Sources/Theseus').rglob('*'):
        target = output / source.relative_to(vendor / 'Sources/Theseus')
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
    changes = {}

    path = output / 'Components/TheseusTabBar.swift'
    original = path.read_text()
    text = replace_once(original,
        '    private var pillSize: CGSize {\n        usesIOS26Look ? Self.iOS26PillSize : Self.pillSize\n    }',
        '    private var pillSize: CGSize {\n'
        '        // ThemeBoard: 3 closer tabs in a 312pt dock; keep original\n'
        '        // spring/morph and enlarge the selected capsule, not the icons.\n'
        '        let native = usesIOS26Look ? Self.iOS26PillSize : Self.pillSize\n'
        '        let available = contentBarFrame.width / max(CGFloat(items.count), 1)\n'
        '        return CGSize(width: min(96, max(native.width, available - 8)), height: native.height)\n'
        '    }', 'larger selection capsule')
    text = replace_once(text,
        '        usesIOS26Look ? 10.25 : 15',
        '        0 // ThemeBoard: equal slots; a 96pt pill leaves 4pt end margins in 312pt.',
        'equal slot end spacing')
    text = replace_once(text,
        '        let size = usesIOS26Look ? Self.iOS26LensSize : Self.lensSize\n        return CGRect(x: itemFrame.midX - size.width / 2, y: itemFrame.midY - size.height / 2, width: size.width, height: size.height)',
        '        let native = usesIOS26Look ? Self.iOS26LensSize : Self.lensSize\n'
        '        let size = CGSize(width: pillSize.width + 16, height: native.height)\n'
        '        return CGRect(x: itemFrame.midX - size.width / 2, y: itemFrame.midY - size.height / 2, width: size.width, height: size.height)',
        'lens matches enlarged resting pill')
    path.write_text(text)
    changes[str(path.relative_to(output))] = {'before': hashlib.sha256(original.encode()).hexdigest(), 'after': hashlib.sha256(text.encode()).hexdigest()}

    from theseus_presentation_fixes import apply
    apply(output, changes, replace_once)

    record = {'upstream_commit': provenance['commit'], 'vendor_modified': False,
              'patches': changes, 'shaders_modified': False, 'renderer_modified': True,
              'capture_modified': True, 'materials_modified': False, 'native_ui_validated': False}
    (output.parent / 'theseus-compatibility.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.root.resolve(), args.output.resolve()), indent=2))
