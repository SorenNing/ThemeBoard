"""Presentation/capture fixes for the pinned build copy; optics stay upstream."""
import hashlib


def apply(output, changes, replace):
    def patch(relative, edits):
        path = output / relative
        before = path.read_text()
        after = before
        for old, new, label in edits:
            after = replace(after, old, new, relative + ': ' + label)
        path.write_text(after)
        changes[relative] = {'before': hashlib.sha256(before.encode()).hexdigest(),
                             'after': hashlib.sha256(after.encode()).hexdigest()}

    patch('Core/TheseusView.swift', [
        ('            renderer?.updateConfiguration(configuration)',
         '            renderer?.updateConfiguration(configuration)\n'
         '            updateLensMask()', 'refresh mask on every morph/inset update'),
        ('    private var metalLayerView: UIView?',
         '    private var metalLayerView: UIView?\n'
         '    private let lensMask = CALayer()\n'
         '\n'
         '    // A moving control lens has a strict transparent capsule boundary.\n'
         '    // Its shader still owns the optics; this contains a rectangular\n'
         '    // drawable/temporary frame at the compositor boundary.\n'
         '    private func updateLensMask() {\n'
         '        guard let host = metalLayerView else { return }\n'
         '        guard configuration.shape.cornerRadius < 0 else {\n'
         '            host.layer.mask = nil\n'
         '            return\n'
         '        }\n'
         '        let shape = configuration.shape\n'
         '        let body = bounds.insetBy(dx: shape.widthInset, dy: shape.heightInset)\n'
         '        guard body.width > 0, body.height > 0 else { host.layer.mask = nil; return }\n'
         '        CATransaction.begin()\n'
         '        CATransaction.setDisableActions(true)\n'
         '        lensMask.backgroundColor = UIColor.black.cgColor\n'
         '        lensMask.bounds = CGRect(origin: .zero, size: body.size)\n'
         '        lensMask.position = CGPoint(x: body.midX - host.frame.minX, y: body.midY - host.frame.minY)\n'
         '        lensMask.cornerRadius = min(body.width, body.height) / 2\n'
         '        lensMask.cornerCurve = .continuous\n'
         '        lensMask.transform = CATransform3DMakeScale(configuration.morph.scale.x, configuration.morph.scale.y, 1)\n'
         '        host.layer.mask = lensMask\n'
         '        CATransaction.commit()\n'
         '    }', 'live lens alpha containment'),
        ('        if metalLayer.drawableSize != drawableSize {',
         '        updateLensMask()\n'
         '        if metalLayer.drawableSize != drawableSize {', 'align mask after layout'),
        ('    public func pauseRendering() {\n        isRenderPausedByOwner = true',
         '    public func pauseRendering() {\n'
         '        resetCaptureSnapshot()\n'
         '        isRenderPausedByOwner = true', 'invalidate paused-page submissions'),
        ('    private(set) var captureSnapshot: CGImage?',
         '    private(set) var captureSnapshot: CGImage?\n'
         '    private var captureRevision: UInt64 = 0\n'
         '    private var capturedLayout: CGRect = .null\n'
         '\n'
         '    private func resetCaptureSnapshot() {\n'
         '        captureRevision &+= 1\n'
         '        captureSnapshot = nil\n'
         '        captureSnapshotOverride = nil\n'
         '        applySnapshotSetting()\n'
         '    }', 'snapshot generation'),
        ('        renderer?.onSnapshot = providesCaptureSnapshot ? { [weak self] image in\n            self?.captureSnapshot = image\n            self?.snapshotDidUpdate?()\n        } : nil',
         '        let revision = captureRevision\n'
         '        let expectedBounds = bounds\n'
         '        renderer?.onSnapshot = providesCaptureSnapshot ? { [weak self] image in\n'
         '            guard let self, self.captureRevision == revision,\n'
         '                  self.bounds == expectedBounds, self.window != nil else { return }\n'
         '            self.captureSnapshot = image\n'
         '            self.snapshotDidUpdate?()\n'
         '        } : nil', 'reject stale submitted snapshots'),
        ('    public weak var sourceView: UIView? {\n        didSet {\n            renderer?.updateSourceView(sourceView ?? superview)\n        }\n    }',
         '    public weak var sourceView: UIView? {\n'
         '        didSet {\n'
         '            guard sourceView !== oldValue else { return }\n'
         '            resetCaptureSnapshot()\n'
         '            renderer?.updateSourceView(sourceView ?? superview)\n'
         '        }\n'
         '    }', 'source revision'),
        ('        let paddingY = padding.y * scale\n        let drawableSize = CGSize(',
         '        let paddingY = padding.y * scale\n'
         '        let paddedFrame = bounds.insetBy(dx: -padding.x, dy: -padding.y)\n'
         '        if capturedLayout != paddedFrame {\n'
         '            capturedLayout = paddedFrame\n'
         '            resetCaptureSnapshot()\n'
         '        }\n'
         '        if metalLayerView?.frame != paddedFrame {\n'
         '            metalLayerView?.frame = paddedFrame\n'
         '            renderer?.setNeedsRender()\n'
         '        }\n'
         '        let drawableSize = CGSize(', 'drawable presentation extent'),
        ('        metalContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]\n        metalContainer.frame = bounds',
         '        metalContainer.isOpaque = false\n        metalContainer.backgroundColor = .clear\n        metalContainer.isUserInteractionEnabled = false\n        metalContainer.autoresizingMask = []\n        metalContainer.frame = bounds', 'transparent host'),
        ('        metalLayer.contentsGravity = .center',
         '        metalLayer.contentsGravity = .resize', 'pixel-aligned padded host'),
        ('        return (metalLayerView?.frame ?? bounds).insetBy(dx: -padding.x, dy: -padding.y)',
         '        return bounds.insetBy(dx: -padding.x, dy: -padding.y)', 'snapshot extent once'),
    ])
    patch('Rendering/TheseusRenderer.swift', [
        ('        let viewFrame = metalLayer.frame\n        let captureRegion = calculateCaptureRegion(viewFrame: viewFrame, in: sourceView)',
         '        // Convert the glass body, then add drawable padding exactly once.\n'
         '        let viewFrame = hostView?.bounds ?? metalLayer.frame\n'
         '        let captureRegion = calculateCaptureRegion(viewFrame: viewFrame, in: sourceView)', 'unpadded capture body'),
        ('        let superAnimating = superlayer.animationKeys()?.isEmpty == false\n        let sourceAnimating = sourceView.layer.animationKeys()?.isEmpty == false',
         '        var ancestor: CALayer? = superlayer\n'
         '        var superAnimating = false\n'
         '        while let layer = ancestor {\n'
         '            if layer.animationKeys()?.isEmpty == false { superAnimating = true; break }\n'
         '            ancestor = layer.superlayer\n'
         '        }\n'
         '        let sourceAnimating = sourceView.layer.animationKeys()?.isEmpty == false', 'navigation ancestor presentation'),
        ('        commandBuffer.addCompletedHandler { [weak self] _ in\n            guard let image = Self.image(from: snapshot) else { return }\n            DispatchQueue.main.async { self?.onSnapshot?(image) }\n        }',
         '        // Keep the consumer belonging to this submitted frame. A later\n'
         '        // source/layout revision must not receive an older GPU snapshot.\n'
         '        let deliverSnapshot = onSnapshot\n'
         '        commandBuffer.addCompletedHandler { _ in\n'
         '            guard let image = Self.image(from: snapshot) else { return }\n'
         '            DispatchQueue.main.async { deliverSnapshot?(image) }\n'
         '        }', 'snapshot consumer at submission'),
    ])
    for relative, anchor in [
        ('Rendering/BackgroundCaptureDraw.swift', '        let hiddenStates = excludedViews.map { $0.isHidden }'),
        ('Rendering/ViewLayerCapture.swift', '        let previousVisibility = excludedViews.map { $0.isHidden }'),
    ]:
        patch(relative, [(anchor,
            '        // Both temporary substitution and restoration stay in the same\n'
            '        // disabled-actions transaction, including all early returns.\n'
            '        CATransaction.begin()\n'
            '        CATransaction.setDisableActions(true)\n'
            '        defer { CATransaction.commit() }\n' + anchor, 'atomic capture substitutions')])
    patch('Rendering/CaptureCompensation.swift', [
        ('        if let glass = view as? TheseusView, let host = glass.captureMetalHost {',
         '        if let glass = view as? TheseusView, let host = glass.captureMetalHost, !host.isHidden {', 'skip inactive Metal backend'),
        ('                let layer = CALayer()\n                layer.contents =',
         '                let layer = CALayer()\n'
         '                layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull()]\n'
         '                layer.contents =', 'passive snapshot layer'),
        ('                glass.layer.addSublayer(layer)',
         '                if glass.configuration.shape.cornerRadius < 0 {\n'
         '                    let shape = glass.configuration.shape\n'
         '                    let body = glass.bounds.insetBy(dx: shape.widthInset, dy: shape.heightInset)\n'
         '                    let mask = CALayer()\n'
         '                    mask.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "transform": NSNull()]\n'
         '                    mask.backgroundColor = UIColor.black.cgColor\n'
         '                    mask.bounds = CGRect(origin: .zero, size: body.size)\n'
         '                    mask.position = CGPoint(x: body.midX - layer.frame.minX, y: body.midY - layer.frame.minY)\n'
         '                    mask.cornerRadius = min(body.width, body.height) / 2\n'
         '                    mask.cornerCurve = .continuous\n'
         '                    mask.transform = CATransform3DMakeScale(glass.configuration.morph.scale.x, glass.configuration.morph.scale.y, 1)\n'
         '                    layer.mask = mask\n'
         '                }\n'
         '                glass.layer.addSublayer(layer)', 'match captured lens alpha boundary'),
        ('            } else {\n                glass.backgroundColor = glass.captureVeilColor\n            }',
         '            } else {\n'
         '                // Never paint a rectangular UIView background for a lens\n'
         '                // whose first GPU snapshot is still in flight.\n'
         '                let shape = glass.configuration.shape\n'
         '                let frame = glass.bounds.insetBy(dx: shape.widthInset, dy: shape.heightInset)\n'
         '                let radius = shape.cornerRadius < 0 ? min(frame.width, frame.height) / 2 : max(0, shape.cornerRadius)\n'
         '                let veil = CALayer()\n'
         '                veil.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull()]\n'
         '                veil.frame = frame\n'
         '                veil.backgroundColor = glass.captureVeilColor.cgColor\n'
         '                veil.cornerRadius = min(radius, min(frame.width, frame.height) / 2)\n'
         '                veil.cornerCurve = .continuous\n'
         '                veil.masksToBounds = true\n'
         '                glass.layer.insertSublayer(veil, at: 0)\n'
         '                entry.snapshotLayer = veil\n'
         '            }', 'rounded first-frame substitute'),
    ])
