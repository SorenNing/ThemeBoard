import UIKit

/// A simple wrapper around UIFeedbackGenerator for haptic feedback
public final class HapticManager {

    /// Haptic impact style
    public enum ImpactStyle {
        case light
        case medium
        case heavy
        case soft
        case rigid

        @available(iOS 13.0, *)
        var feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light:
                return .light
            case .medium:
                return .medium
            case .heavy:
                return .heavy
            case .soft:
                return .soft
            case .rigid:
                return .rigid
            }
        }
    }

    /// Haptic notification type
    public enum NotificationType {
        case success
        case warning
        case error

        var feedbackType: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success:
                return .success
            case .warning:
                return .warning
            case .error:
                return .error
            }
        }
    }

    private var impactGenerator: UIImpactFeedbackGenerator?
    private var selectionGenerator: UISelectionFeedbackGenerator?
    private var notificationGenerator: UINotificationFeedbackGenerator?

    public init() {}

    public func prepareImpact(_ style: ImpactStyle) {
        if #available(iOS 13.0, *) {
            impactGenerator = UIImpactFeedbackGenerator(style: style.feedbackStyle)
            impactGenerator?.prepare()
        }
    }

    public func impact(_ style: ImpactStyle) {
        if #available(iOS 13.0, *) {
            let generator = UIImpactFeedbackGenerator(style: style.feedbackStyle)
            generator.impactOccurred()
        }
    }

    public func impact(_ style: ImpactStyle, intensity: CGFloat) {
        if #available(iOS 13.0, *) {
            let generator = UIImpactFeedbackGenerator(style: style.feedbackStyle)
            generator.impactOccurred(intensity: intensity)
        }
    }

    public func prepareSelection() {
        selectionGenerator = UISelectionFeedbackGenerator()
        selectionGenerator?.prepare()
    }

    public func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    public func prepareNotification() {
        notificationGenerator = UINotificationFeedbackGenerator()
        notificationGenerator?.prepare()
    }

    public func notification(_ type: NotificationType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type.feedbackType)
    }
}
