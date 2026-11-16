import UIKit
import QuartzCore

/// Shares a visibility check across surfaces. Upstream renderers detect frame
/// changes themselves; static cards stay event-driven, not continuously sampled.
@MainActor
private final class TBSurfaceVisibility: NSObject {
    static let shared = TBSurfaceVisibility()
    private let surfaces = NSHashTable<TBTheseusSurface>.weakObjects()
    private var link: CADisplayLink?

    func register(_ surface: TBTheseusSurface) {
        surfaces.add(surface)
        guard link == nil else { return }
        let driver = CADisplayLink(target: self, selector: #selector(tick))
        driver.preferredFramesPerSecond = 15
        driver.add(to: .main, forMode: .common)
        link = driver
    }

    func unregister(_ surface: TBTheseusSurface) {
        surfaces.remove(surface)
        if surfaces.allObjects.isEmpty { stop() }
    }

    private func stop() { link?.invalidate(); link = nil }

    @objc private func tick() {
        let active = surfaces.allObjects
        if active.isEmpty { stop(); return }
        for surface in active { surface.refreshVisibility() }
    }
}

/// The original regular glass preset. The host's foreground subtree is excluded
/// from capture so text, symbols, photos and controls do not refract themselves.
@objc(TBTheseusSurface)
final class TBTheseusSurface: UIView {
    private let glass = TheseusView(configuration: .regular)
    private var renderingVisible = false
    private var lastWindowFrame: CGRect = .null
    private var lastBackdropRefresh: CFTimeInterval = 0
    private var warmupFrames = 2

    private var lastExclusions: [ObjectIdentifier] = []
    @objc var cornerRadius: CGFloat = 20 {
        didSet { if cornerRadius != oldValue { updateMaterial() } }
    }
    @objc var surfaceTint: UIColor? {
        didSet { if surfaceTint != oldValue { updateMaterial() } }
    }
    @objc weak var captureExclusion: UIView? {
        didSet { if captureExclusion !== oldValue { updateCapture() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }
    private func configure() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        glass.isUserInteractionEnabled = false
        glass.continuousUpdate = false
        glass.providesCaptureSnapshot = true
        glass.pauseRendering()
        addSubview(glass)
        updateMaterial()
    }

    private func updateMaterial() {
        var config = TheseusConfiguration.regular
        config.shape.cornerRadius = max(0, cornerRadius)
        config.theme.isDark = traitCollection.userInterfaceStyle == .dark
        // Match the upstream controls' device/simulator capture choice.
        config.captureMethod = TheseusCapability.isDeviceSupported ? .layerRendering : .surfaceBased
        config = config.tint(surfaceTint)
        glass.configuration = config
    }

    private func updateCapture() {
        guard let window else { return }
        var excluded: [UIView] = [captureExclusion ?? self]
        // layer.render captures the whole source tree, including siblings in
        // front of this host. Exclude those explicitly; keep the actual page
        // behind a sheet, and lower sibling glass snapshots, available.
        var branch: UIView = captureExclusion ?? self
        while let parent = branch.superview {
            if let index = parent.subviews.firstIndex(where: { $0 === branch }) {
                excluded.append(contentsOf: parent.subviews.dropFirst(index + 1))
            }
            if parent === window { break }
            branch = parent
        }
        let identities = excluded.map { ObjectIdentifier($0) }
        if glass.sourceView !== window || identities != lastExclusions {
            lastExclusions = identities
            glass.sourceView = window
            glass.setCaptureExcludedViews(excluded)
            warmupFrames = 2
            glass.invalidateBackground()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            updateCapture()
            TBSurfaceVisibility.shared.register(self)
            refreshVisibility()
        } else {
            glass.pauseRendering()
            renderingVisible = false
            lastWindowFrame = .null
            TBSurfaceVisibility.shared.unregister(self)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if glass.frame != bounds { glass.frame = bounds }
        refreshVisibility()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateMaterial()
        invalidateBackground()
    }

    fileprivate func refreshVisibility() {
        guard let window else { return }
        var visible = UIApplication.shared.applicationState != .background && !bounds.isEmpty
        let rect = convert(bounds, to: window)
        visible = visible && rect.intersects(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor, visible {
            visible = !view.isHidden && view.alpha > 0.001
            if view.clipsToBounds {
                visible = rect.intersects(view.convert(view.bounds, to: window))
            }
            ancestor = view.superview
        }
        if visible { updateCapture() }
        if visible != renderingVisible {
            renderingVisible = visible
            if visible { glass.resumeRendering(); glass.invalidateBackground() }
            else { glass.pauseRendering() }
        }
        let now = CACurrentMediaTime()
        if visible, rect != lastWindowFrame || warmupFrames > 0 || now - lastBackdropRefresh >= 1 {
            lastWindowFrame = rect
            warmupFrames = max(0, warmupFrames - 1)
            lastBackdropRefresh = now
            glass.invalidateBackground()
        }
    }

    @objc func invalidateBackground() { glass.invalidateBackground() }
}

@objc(TBTheseusSwitch)
final class TBTheseusSwitch: UIControl {
    private let control = TheseusSwitch()
    @objc var on: Bool {
        get { control.isOn }
        set { control.isOn = newValue }
    }
    @objc(isOn) func isOn() -> Bool { control.isOn }

    override init(frame: CGRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        addSubview(control)
        control.addTarget(self, action: #selector(changed), for: .valueChanged)
        if bounds.isEmpty { bounds.size = control.intrinsicContentSize }
    }
    override var intrinsicContentSize: CGSize { control.intrinsicContentSize }
    override func layoutSubviews() { super.layoutSubviews(); control.frame = bounds }
    override var isEnabled: Bool { didSet { control.isEnabled = isEnabled } }
    @objc(setOn:animated:) func setOn(_ on: Bool, animated: Bool) { control.setOn(on, animated: animated) }
    @objc private func changed() { sendActions(for: .valueChanged) }
}

/// Same-module subclass changes only the Objective-C event forwarding hooks;
/// original Theseus optics, geometry and tracking implementation run via super.
private final class TBTrackedTheseusSlider: TheseusSlider {
    var trackingActive = false
    var began: (() -> Void)?
    var ended: ((Bool) -> Void)?
    var cancelled: (() -> Void)?

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let accepted = super.beginTracking(touch, with: event)
        if accepted { trackingActive = true; began?() }
        return accepted
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let inside = touch.map { bounds.contains($0.location(in: self)) } ?? false
        super.endTracking(touch, with: event)
        trackingActive = false
        ended?(inside)
    }
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        trackingActive = false
        cancelled?()
    }
}

@objc(TBTheseusSlider)
final class TBTheseusSlider: UIControl {
    private let control = TBTrackedTheseusSlider()
    @objc var minimumValue: Float {
        get { Float(control.minimumValue) }
        set { control.minimumValue = CGFloat(newValue) }
    }
    @objc var maximumValue: Float {
        get { Float(control.maximumValue) }
        set { control.maximumValue = CGFloat(newValue) }
    }
    @objc var value: Float {
        get { Float(control.value) }
        set { control.setValue(CGFloat(newValue), animated: false) }
    }
    @objc var continuous: Bool = true
    @objc(isContinuous) func isContinuous() -> Bool { continuous }

    override init(frame: CGRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        addSubview(control)
        control.addTarget(self, action: #selector(changed), for: .valueChanged)
        control.began = { [weak self] in self?.sendActions(for: .touchDown) }
        control.ended = { [weak self] inside in
            guard let self else { return }
            if !self.continuous { self.sendActions(for: .valueChanged) }
            self.sendActions(for: inside ? .touchUpInside : .touchUpOutside)
        }
        control.cancelled = { [weak self] in self?.sendActions(for: .touchCancel) }
    }
    override var intrinsicContentSize: CGSize { control.intrinsicContentSize }
    override func layoutSubviews() { super.layoutSubviews(); control.frame = bounds }
    override var isEnabled: Bool { didSet { control.isEnabled = isEnabled } }
    @objc(setValue:animated:) func setValue(_ value: Float, animated: Bool) {
        control.setValue(CGFloat(value), animated: animated)
    }
    @objc private func changed() {
        if continuous || !control.trackingActive { sendActions(for: .valueChanged) }
    }
}
