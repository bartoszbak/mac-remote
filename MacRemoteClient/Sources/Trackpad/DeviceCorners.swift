import UIKit

/// Corner radius of the device's display, so controls pinned to the screen edge can use
/// concentric corners. Falls back to 0 on square-cornered devices and in previews.
enum DeviceCorners {
    static let radius: CGFloat = {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
        let key = ["_display", "CornerRadius"].joined()
        guard let screen, let value = screen.value(forKey: key) as? CGFloat, value > 0 else {
            return 0
        }
        return value
    }()

    /// Radius for a control inset `inset` points from the screen edge, never smaller than `minimum`.
    static func concentric(inset: CGFloat, minimum: CGFloat = 16) -> CGFloat {
        max(radius - inset, minimum)
    }
}
