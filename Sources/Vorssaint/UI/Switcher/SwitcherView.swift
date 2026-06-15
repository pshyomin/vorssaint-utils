import SwiftUI

/// Content of the switcher panel: a grid of large window cards with live
/// thumbnails, hover/keyboard selection and a springy highlight.
struct SwitcherView: View {
    @EnvironmentObject private var switcher: AppSwitcher
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Group {
            if switcher.windows.isEmpty {
                Text(l10n.s.switcherNoWindows)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cardGrid
            }
        }
        .padding(SwitcherGrid.padding)
        .background(HUDBackdrop(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var cardGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(SwitcherGrid.cardWidth),
                                                       spacing: SwitcherGrid.spacing),
                                   count: switcher.grid.columns),
                    spacing: SwitcherGrid.spacing
                ) {
                    ForEach(Array(switcher.windows.enumerated()), id: \.element.id) { index, window in
                        WindowCard(window: window,
                                   preview: window.previewWindowID.flatMap { switcher.previews[$0] },
                                   isSelected: index == switcher.selectedIndex)
                            .id(window.id)
                            .onHover { hovering in
                                if hovering { switcher.hoverSelect(index: index) }
                            }
                            .onTapGesture {
                                switcher.select(index: index)
                                switcher.commitSession()
                            }
                    }
                }
            }
            .scrollDisabled(switcher.grid.rows <= switcher.grid.visibleRows)
            .onChange(of: switcher.selectedIndex) { _, newIndex in
                guard switcher.windows.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(switcher.windows[newIndex].id, anchor: nil)
                }
            }
        }
    }
}

private struct WindowCard: View {
    let window: SwitcherItem
    let preview: CGImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                if let preview {
                    Image(decorative: preview, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(5)
                } else if let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                }

                // Small app badge over the thumbnail corner.
                if preview != nil, let icon = window.appIcon {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 32, height: 32)
                                .shadow(radius: 3)
                                .padding(7)
                        }
                    }
                }
            }
            .frame(width: SwitcherGrid.cardWidth - 20,
                   height: SwitcherGrid.cardHeight - 58)

            Text(window.displayTitle)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: SwitcherGrid.cardWidth - 28)
        }
        .padding(10)
        .frame(width: SwitcherGrid.cardWidth, height: SwitcherGrid.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isSelected ? 1.0 : 0.97)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}
