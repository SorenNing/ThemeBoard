#!/usr/bin/env python3
"""Static source/geometry regression checks; no device/GPU execution implied."""
from pathlib import Path
from tempfile import TemporaryDirectory
import hashlib, json, math
from prepare_theseus_sources import prepare


def check(root):
    vendor = root / 'Vendor/Theseus/Sources/Theseus'
    with TemporaryDirectory(prefix='themeboard-presentation-') as work:
        stage = Path(work) / 'Theseus'
        receipt = prepare(root, stage)
        required = {'Core/TheseusView.swift', 'Components/TheseusTabBar.swift',
                    'Rendering/TheseusRenderer.swift', 'Rendering/CaptureCompensation.swift',
                    'Rendering/BackgroundCaptureDraw.swift', 'Rendering/ViewLayerCapture.swift'}
        assert set(receipt['patches']) == required
        for path in vendor.rglob('*'):
            if path.is_file() and path.relative_to(vendor).as_posix() not in required:
                assert path.read_bytes() == (stage / path.relative_to(vendor)).read_bytes(), str(path)
        view = (stage / 'Core/TheseusView.swift').read_text()
        assert 'metalContainer.isOpaque = false' in view
        assert 'metalLayer.contentsGravity = .resize' in view
        assert 'metalLayerView?.frame = paddedFrame' in view
        assert 'host.layer.mask = lensMask' in view
        assert 'lensMask.cornerCurve = .continuous' in view
        assert 'configuration.shape.cornerRadius < 0' in view
        assert view.count('updateLensMask()') == 3
        assert 'self.captureRevision == revision' in view
        assert 'resetCaptureSnapshot()\n        isRenderPausedByOwner = true' in view
        capture = (stage / 'Rendering/CaptureCompensation.swift').read_text()
        assert 'glass.backgroundColor = glass.captureVeilColor' not in capture
        assert 'layer.mask = mask' in capture and 'veil.cornerRadius = min(radius,' in capture
        for relative in ['Rendering/BackgroundCaptureDraw.swift', 'Rendering/ViewLayerCapture.swift']:
            text = (stage / relative).read_text()
            assert text.index('CATransaction.setDisableActions(true)') < text.index('excludedViews.forEach')
            assert 'defer { CATransaction.commit() }' in text
        renderer = (stage / 'Rendering/TheseusRenderer.swift').read_text()
        assert 'let deliverSnapshot = onSnapshot' in renderer
        assert 'let viewFrame = hostView?.bounds ?? metalLayer.frame' in renderer
        for name in ['TheseusSwitch', 'TheseusTabBar', 'TheseusSlider']:
            component = (stage / ('Components/' + name + '.swift')).read_text()
            assert 'TheseusView(configuration: config)' in component
            assert 'shape.cornerRadius = -' in component or 'lensCornerRadius(forHeight:' in component
        # The Metal body, padded drawable and snapshot use exactly one apron.
        # Test small switch thumbs, the resting/drag tab capsule, and large cards
        # at physical screen scales and non-uniform morph scale factors.
        cases = 0
        for width, height in [(26, 24), (39, 33), (96, 56), (112, 66), (312, 64), (360, 78)]:
            for px, py in [(0, 0), (12, 12), (18, 18)]:
                for scale in [2, 3]:
                    for ix, iy in [(0, 0), (-0.8, -0.8), (3, 2)]:
                        padded = (-px, -py, width + 2 * px, height + 2 * py)
                        body = (ix, iy, width - 2 * ix, height - 2 * iy)
                        center = (body[0] + body[2] / 2 - padded[0], body[1] + body[3] / 2 - padded[1])
                        assert all(math.isclose(a, b, abs_tol=1e-9) for a, b in zip(center, (padded[2] / 2, padded[3] / 2)))
                        for sx, sy in [(1, 1), (1.17, 0.91), (0.88, 1.12)]:
                            radius = min(body[2], body[3]) / 2
                            # The live mask and snapshot mask use the same local
                            # coordinates; corners outside the stadium remain clear.
                            x, y = -body[2] / 2, -body[3] / 2
                            qx = abs(x / sx) - (body[2] / 2 - radius)
                            qy = abs(y / sy) - (body[3] / 2 - radius)
                            d = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
                            assert math.isfinite(d)
                            if sx == 1 and sy == 1: assert d > 0
                            cases += 1
        return {'passed': True, 'geometry_cases': cases, 'patched_files': sorted(required),
                'shader_unchanged': True, 'native_swift_metal_tested': False, 'device_ui_tested': False}

if __name__ == '__main__':
    print(json.dumps(check(Path(__file__).resolve().parents[1]), indent=2))
