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

    /// Soft scroll-edge effect under the navigation bar on iOS 26 and later. No-op before that.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Background for keyboard keys and chips: Liquid Glass on iOS 26 and later (tinted with
    /// the accent colour when `tinted`), a plain grey or accent fill before that.
    @ViewBuilder
    func keyGlass(tinted: Bool = false, in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(tinted ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: shape)
        } else {
            self.background(tinted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.systemGray5)), in: shape)
        }
    }
}
