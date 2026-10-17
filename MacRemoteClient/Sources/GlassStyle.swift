import SwiftUI

extension View {
    /// Prominent glass button on iOS 26 and later; bordered prominent before that.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// The iOS 26 search design: the field lives in the bottom toolbar and collapses to a
    /// button until tapped. No-op before iOS 26, where `searchable` keeps its classic placement.
    @ViewBuilder
    func minimizedSearchToolbar() -> some View {
        if #available(iOS 26, *) {
            self.searchToolbarBehavior(.minimize)
        } else {
            self
        }
    }

    /// Soft scroll-edge effect under the navigation bar on iOS 26 and later. No-op before that.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
