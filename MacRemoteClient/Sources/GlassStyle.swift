import SwiftUI

extension View {
    /// Liquid Glass tinted towards black on iOS 26 and later, so it sits just above a black
    /// surface and lightens while pressed; a dark translucent material before that.
    @ViewBuilder
    func padGlass<S: Shape>(in shape: S, pressed: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(.black.opacity(pressed ? 0.05 : 0.2)), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(.black.opacity(pressed ? 0.08 : 0.25)))
                .clipShape(shape)
        }
    }

    /// Groups neighbouring glass views so they are rendered together. On iOS 26 and later
    /// this is required for correct output when glass elements sit close to each other.
    @ViewBuilder
    func glassGroup(spacing: CGFloat) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
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

#Preview("Pad glass") {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack(spacing: 10) {
            Color.clear.padGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Color.clear.padGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), pressed: true)
        }
        .frame(height: 84)
        .padding()
    }
}
