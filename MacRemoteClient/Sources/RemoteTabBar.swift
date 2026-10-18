import SwiftUI

/// Bottom bar for switching sections: a horizontally scrolling row of chips that act as
/// tabs. The selected chip is Liquid Glass (iOS 26+) and is kept in view; the glass slides
/// to the new chip when the selection changes.
struct RemoteTabBar: View {
    @Binding var selection: RemoteTab
    @Namespace private var glassNamespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                chips
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, tab in
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .overlay(alignment: .top) { Divider() }
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private var chips: some View {
        let row = HStack(spacing: 8) {
            ForEach(RemoteTab.allCases) { tab in
                RemoteTabChip(tab: tab, isSelected: tab == selection, glassNamespace: glassNamespace) {
                    withAnimation(.snappy(duration: 0.3)) { selection = tab }
                }
                .id(tab)
            }
        }
        if #available(iOS 26, *) {
            // One container so the selected chip's glass can morph from chip to chip.
            GlassEffectContainer(spacing: 8) { row }
        } else {
            row
        }
    }
}

/// One section in the bar: icon and title in a capsule. Selected is Liquid Glass on
/// iOS 26+ (a solid fill before that); the others sit on a quiet grey fill.
struct RemoteTabChip: View {
    let tab: RemoteTab
    let isSelected: Bool
    var glassNamespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            styled(
                Label(tab.title, systemImage: tab.systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.body.weight(isSelected ? .semibold : .medium))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func styled(_ label: some View) -> some View {
        if #available(iOS 26, *) {
            if isSelected {
                label
                    .foregroundStyle(Color.primary)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("selected", in: glassNamespace)
            } else {
                label
                    .foregroundStyle(Color.secondary)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
            }
        } else {
            label
                .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
                .background(Capsule().fill(isSelected ? Color(.label) : Color(.tertiarySystemFill)))
        }
    }
}

#Preview("Tab bar") {
    struct Host: View {
        @State private var tab: RemoteTab = .trackpad
        var body: some View {
            VStack {
                Spacer()
                Text(tab.title)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { RemoteTabBar(selection: $tab) }
        }
    }
    return Host()
}
