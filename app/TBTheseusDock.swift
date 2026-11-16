import UIKit

/// A narrow Objective-C adapter. All visual and motion behavior stays in the
/// unmodified, pinned TheseusTabBar implementation under Vendor/Theseus.
@objc(TBTheseusDock)
final class TBTheseusDock: UIView, UIGestureRecognizerDelegate {
    private let bar = TheseusTabBar()
    private var indexAtTouchDown = 0
    private var tapGeneration = 0
    private weak var reselectTap: UITapGestureRecognizer?
    private var refreshLink: DisplayLinkDriver.Link?
    private var lastRefreshTime: CFTimeInterval = 0
    private var lastHierarchyScan: CFTimeInterval = 0
    private let scrollViews = NSHashTable<UIScrollView>.weakObjects()
    private let motionLayers = NSHashTable<CALayer>.weakObjects()
    private var accessibleItems: [TBTabAccessibilityElement] = []

    @objc var onSelection: ((Int) -> Void)?
    @objc var onReselection: ((Int) -> Void)?

    @objc var selectedIndex: Int {
        get { bar.selectedIndex }
        set {
            guard bar.items.indices.contains(newValue), newValue != bar.selectedIndex else { return }
            bar.selectedIndex = newValue
        }
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
        backgroundColor = .clear
        clipsToBounds = false
        accessibilityIdentifier = "themeboard.theseus.dock"
        // ThemeBoard owns its established geometry; Theseus keeps the optics,
        // gestures and springs. Do not shrink three tabs to the 198pt default.
        bar.barHeight = 64
        bar.items = [
            TheseusTabBarItem(icon: UIImage(systemName: "square.grid.2x2.fill"), title: "主题"),
            TheseusTabBarItem(icon: UIImage(systemName: "slider.horizontal.3"), title: "设置"),
            TheseusTabBarItem(icon: UIImage(systemName: "waveform.path.ecg"), title: "状态")
        ]
        bar.onItemSelected = { [weak self] index in
            self?.onSelection?(index)
        }
        addSubview(bar)
        let upstreamItems = bar.accessibilityElements?.compactMap { $0 as? UIView } ?? []
        accessibleItems = upstreamItems.enumerated().map { index, item in
            let proxy = TBTabAccessibilityElement(accessibilityContainer: bar)
            proxy.itemView = item
            proxy.activate = { [weak self] in
                guard let self else { return false }
                if self.bar.selectedIndex == index { self.onReselection?(index) }
                else { self.bar.selectedIndex = index; self.onSelection?(index) }
                return true
            }
            return proxy
        }
        bar.accessibilityElements = accessibleItems

        // The old app reselects a tab to pop its navigation stack. Observe only
        // completed taps; the upstream recognizers still own lift, drag, and
        // cancellation. No item coordinates or spring constants are copied.
        let tap = UITapGestureRecognizer(target: self, action: #selector(reselected(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        bar.addGestureRecognizer(tap)
        reselectTap = tap
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 64)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bar.frame != bounds { bar.frame = bounds }
        let styleScale: CGFloat = TheseusSettings.shared.effectiveGlassStyle == .iOS26 ? 328.0 / 330.0 : 1
        let itemWidth = bounds.width / max(CGFloat(bar.items.count) * styleScale, 1)
        if abs(bar.preferredItemWidth - itemWidth) > 0.001 { bar.preferredItemWidth = itemWidth }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshLink?.invalidate()
        refreshLink = nil
        if window != nil {
            collectScrollViews()
            refreshLink = DisplayLinkDriver.shared.add(framesPerSecond: .fps(60)) { [weak self] time in
                self?.refreshBackdrop(at: time)
            }
        }
    }

    private func collectScrollViews() {
        scrollViews.removeAllObjects()
        motionLayers.removeAllObjects()
        guard let root = window?.rootViewController?.view else { return }
        func collect(_ view: UIView) {
            guard view !== self, !view.isHidden else { return }
            if let scroll = view as? UIScrollView { scrollViews.add(scroll) }
            // Child page and navigation-transition containers live near the root;
            // cache their layers without scanning the entire tree every frame.
            motionLayers.add(view.layer)
            for child in view.subviews { collect(child) }
        }
        collect(root)
    }

    private func refreshBackdrop(at time: CFTimeInterval) {
        guard let window, !isHidden, alpha > 0.001,
              UIApplication.shared.applicationState == .active else { return }
        let scrolling = scrollViews.allObjects.contains { scroll in
            guard !scroll.isHidden, scroll.alpha > 0.001,
                  scroll.isTracking || scroll.isDragging || scroll.isDecelerating else { return false }
            return scroll.convert(scroll.bounds, to: window).intersects(window.bounds)
        }
        if time - lastHierarchyScan >= 0.25 {
            lastHierarchyScan = time
            collectScrollViews()
        }
        let animated = motionLayers.allObjects.contains { !($0.animationKeys()?.isEmpty ?? true) }
        if scrolling || animated || time - lastRefreshTime >= 0.25 {
            lastRefreshTime = time
            bar.invalidateBackground()
        }
    }

    @objc func invalidateBackground() { bar.invalidateBackground() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === reselectTap else { return true }
        indexAtTouchDown = bar.selectedIndex
        tapGeneration += 1
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === bar && otherGestureRecognizer.view === bar
    }

    @objc private func reselected(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        let previous = indexAtTouchDown
        let generation = tapGeneration
        // Let Theseus finish its press commit before checking re-selection.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tapGeneration == generation,
                  self.bar.selectedIndex == previous else { return }
            self.onReselection?(previous)
        }
    }
}

/// Preserves the original item's label, traits and frame; only activation is
/// adapted so reselect-to-pop works for VoiceOver as well as a physical tap.
private final class TBTabAccessibilityElement: UIAccessibilityElement {
    weak var itemView: UIView?
    var activate: (() -> Bool)?
    override var accessibilityLabel: String? {
        get { itemView?.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }
    override var accessibilityTraits: UIAccessibilityTraits {
        get { itemView?.accessibilityTraits ?? [.button] }
        set { super.accessibilityTraits = newValue }
    }
    override var accessibilityFrame: CGRect {
        get { itemView.map { UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0) } ?? .zero }
        set { super.accessibilityFrame = newValue }
    }
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}
