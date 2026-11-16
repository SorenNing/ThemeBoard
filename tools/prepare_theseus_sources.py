#!/usr/bin/env python3
"""Stage Theseus with explicit, audited iOS presentation fixes.

Vendor files are untouched. Patch the disposable build copy and record hashes;
never silently substitute different shaders, physics or control implementations.
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

    path = output / 'Core/TheseusView.swift'
    original = path.read_text()
    text = replace_once(original,
        '        return (metalLayerView?.frame ?? bounds).insetBy(dx: -padding.x, dy: -padding.y)',
        '        return bounds.insetBy(dx: -padding.x, dy: -padding.y)', 'snapshot extent')
    text = replace_once(text,
        '        metalContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]\n        metalContainer.frame = bounds',
        '        // ThemeBoard: explicitly size the Metal host to its padded drawable.\n'
        '        // Do not rely on CAMetalLayer interpreting contentsGravity.center.\n'
        '        metalContainer.isOpaque = false\n'
        '        metalContainer.backgroundColor = .clear\n'
        '        metalContainer.isUserInteractionEnabled = false\n'
        '        metalContainer.autoresizingMask = []\n'
        '        metalContainer.frame = bounds', 'transparent Metal host')
    text = replace_once(text, '        metalLayer.contentsGravity = .center',
        '        metalLayer.contentsGravity = .resize', 'one-to-one drawable')
    text = replace_once(text,
        '        let paddingY = padding.y * scale\n        let drawableSize = CGSize(',
        '        let paddingY = padding.y * scale\n'
        '        let presentationFrame = bounds.insetBy(dx: -padding.x, dy: -padding.y)\n'
        '        if metalLayerView?.frame != presentationFrame {\n'
        '            metalLayerView?.frame = presentationFrame\n'
        '            renderer?.setNeedsRender()\n'
        '        }\n'
        '        let drawableSize = CGSize(', 'padded presentation extent')
    path.write_text(text)
    changes[str(path.relative_to(output))] = {'before': hashlib.sha256(original.encode()).hexdigest(), 'after': hashlib.sha256(text.encode()).hexdigest()}

    path = output / 'Rendering/TheseusRenderer.swift'
    original = path.read_text()
    text = replace_once(original, '        let viewFrame = metalLayer.frame\n        let captureRegion = calculateCaptureRegion(viewFrame: viewFrame, in: sourceView)',
        '        // ThemeBoard: the Metal layer is now the padded presentation.\n'
        '        // Capture starts at the glass body, adding its padding exactly once.\n'
        '        // metalLayer.superlayer is the glass view.layer; use its\n'
        '        // unpadded body bounds, then expand once in captureRegion.\n'
        '        let viewFrame = hostView?.bounds ?? metalLayer.frame\n'
        '        let captureRegion = calculateCaptureRegion(viewFrame: viewFrame, in: sourceView)', 'capture body extent')
    path.write_text(text)
    changes[str(path.relative_to(output))] = {'before': hashlib.sha256(original.encode()).hexdigest(), 'after': hashlib.sha256(text.encode()).hexdigest()}

    path = output / 'Rendering/CaptureCompensation.swift'
    original = path.read_text()
    text = replace_once(original,
        '            } else {\n                glass.backgroundColor = glass.captureVeilColor\n            }',
        '            } else {\n'
        '                // ThemeBoard: a no-snapshot stand-in must use the glass\n'
        '                // contour. A UIView background paints a rectangular plate.\n'
        '                let shape = glass.configuration.shape\n'
        '                let frame = glass.bounds.insetBy(dx: shape.widthInset, dy: shape.heightInset)\n'
        '                let veil = CALayer()\n'
        '                veil.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]\n'
        '                veil.frame = frame\n'
        '                veil.backgroundColor = glass.captureVeilColor.cgColor\n'
        '                veil.cornerRadius = min(abs(shape.cornerRadius), min(frame.width, frame.height) / 2)\n'
        '                veil.cornerCurve = .continuous\n'
        '                veil.masksToBounds = true\n'
        '                glass.layer.insertSublayer(veil, at: 0)\n'
        '                entry.snapshotLayer = veil\n'
        '            }', 'rounded no-snapshot stand-in')
    path.write_text(text)
    changes[str(path.relative_to(output))] = {'before': hashlib.sha256(original.encode()).hexdigest(), 'after': hashlib.sha256(text.encode()).hexdigest()}
    for relative in ['Rendering/BackgroundCaptureDraw.swift', 'Rendering/ViewLayerCapture.swift']:
        path = output / relative
        original = path.read_text()
        anchor = ('        let hiddenStates = excludedViews.map { $0.isHidden }' if 'BackgroundCaptureDraw' in relative
                  else '        let previousVisibility = excludedViews.map { $0.isHidden }')
        text = replace_once(original, anchor,
            '        // ThemeBoard: temporary capture substitutions must never animate\n'
            '        // or commit a rectangular veil into the live presentation tree.\n'
            '        CATransaction.begin()\n'
            '        CATransaction.setDisableActions(true)\n'
            '        defer { CATransaction.commit() }\n' + anchor,
            relative + ' capture transaction')
        path.write_text(text)
        changes[relative] = {'before': hashlib.sha256(original.encode()).hexdigest(), 'after': hashlib.sha256(text.encode()).hexdigest()}

    record = {'upstream_commit': provenance['commit'], 'vendor_modified': False,
              'patches': changes, 'shaders_modified': False, 'native_ui_validated': False}
    (output.parent / 'theseus-compatibility.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.root.resolve(), args.output.resolve()), indent=2))
