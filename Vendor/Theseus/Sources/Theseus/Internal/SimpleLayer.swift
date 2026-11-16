import QuartzCore

/// A CALayer subclass that disables implicit animations for common properties.
/// This is useful for performance-critical rendering where animations are handled manually.
public class SimpleLayer: CALayer {

    override public init() {
        super.init()
    }

    override public init(layer: Any) {
        super.init(layer: layer)
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override public func action(forKey event: String) -> CAAction? {
        switch event {
        case "bounds", "position", "frame", "anchorPoint",
             "transform", "sublayerTransform",
             "backgroundColor", "borderColor", "borderWidth",
             "cornerRadius", "opacity", "shadowColor",
             "shadowOffset", "shadowOpacity", "shadowRadius",
             "contents", "contentsScale", "contentsRect",
             "hidden", "masksToBounds", "zPosition":
            return NSNull()
        default:
            return super.action(forKey: event)
        }
    }
}

/// A simple shape layer with disabled implicit animations
public class SimpleShapeLayer: CAShapeLayer {

    override public init() {
        super.init()
    }

    override public init(layer: Any) {
        super.init(layer: layer)
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override public func action(forKey event: String) -> CAAction? {
        switch event {
        case "bounds", "position", "frame", "anchorPoint",
             "transform", "sublayerTransform",
             "backgroundColor", "borderColor", "borderWidth",
             "cornerRadius", "opacity", "shadowColor",
             "shadowOffset", "shadowOpacity", "shadowRadius",
             "contents", "contentsScale", "contentsRect",
             "hidden", "masksToBounds", "zPosition",
             "path", "fillColor", "strokeColor", "lineWidth":
            return NSNull()
        default:
            return super.action(forKey: event)
        }
    }
}
