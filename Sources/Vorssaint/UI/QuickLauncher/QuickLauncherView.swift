// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct QuickLauncherView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var launcher = QuickLauncherService.shared
    @ObservedObject private var keepAwake = KeepAwakeManager.shared
    @ObservedObject private var micMute = MicMuteService.shared
    @State private var hoveredItem: QuickLauncherItem?
    @State private var draggingItem: QuickLauncherItem?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: QuickLauncherService.columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let utility = launcher.activeUtility {
                hostedUtility(utility)
            } else if launcher.visibleItems.isEmpty && !launcher.isEditing {
                emptyState
            } else {
                grid
            }
            if launcher.activeUtility == nil, launcher.isEditing, !launcher.hiddenItems.isEmpty {
                hiddenTray
            }
            footer
        }
        .padding(16)
        .frame(width: 420)
        .background(HUDBackdrop(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onChange(of: launcher.presentationID) { _, _ in
            hoveredItem = nil
            draggingItem = nil
        }
        .onChange(of: launcher.activeUtility) { _, _ in
            launcher.refreshPanelLayout()
        }
        .onChange(of: launcher.isEditing) { _, _ in
            launcher.refreshPanelLayout()
        }
    }

    /// The utility runs right here inside the launcher; its own close button
    /// and Esc lead back to the grid.
    @ViewBuilder
    private func hostedUtility(_ item: QuickLauncherItem) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                switch item {
                case .homebrew:
                    PanelHomebrewView { launcher.closeUtility() }
                case .media:
                    PanelMediaView { launcher.closeUtility() }
                case .urlCleaner:
                    PanelURLCleanerView { launcher.closeUtility() }
                case .uninstaller:
                    PanelUninstallerView { launcher.closeUtility() }
                case .windowLayout:
                    PanelWindowLayoutView { launcher.closeUtility() }
                default:
                    EmptyView()
                }
            }
        }
        .frame(height: 470)
    }

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                // The same transparent mark the menu panel shows, centered.
                BrandMark(width: 52, tint: colorScheme == .light ? Color(white: 0.03) : .white)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)
                HStack {
                    Spacer()
                    if launcher.activeUtility != nil {
                        Button {
                            launcher.closeUtility()
                        } label: {
                            Image(systemName: "chevron.backward.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                launcher.isEditing.toggle()
                            }
                        } label: {
                            Image(systemName: launcher.isEditing ? "checkmark.circle.fill" : "slider.horizontal.3")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(launcher.isEditing ? Color.accentColor : Color.secondary)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.s.launcherEditHint)
                    }
                }
            }
            if launcher.isEditing, launcher.activeUtility == nil {
                Text(l10n.s.launcherEditHint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(launcher.visibleItems) { item in
                PanelReorderableItem(item: item,
                                     isEnabled: launcher.isEditing,
                                     order: launcher.itemOrderBinding,
                                     dragging: $draggingItem) {
                    cell(item)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: QuickLauncherItem) -> some View {
        let index = launcher.visibleItems.firstIndex(of: item)
        let isSelected = !launcher.isEditing && index != nil && index == launcher.selectedIndex
        let isHovered = hoveredItem == item

        Button {
            launcher.run(item)
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(iconBackground(item, isSelected: isSelected, isHovered: isHovered))
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(systemName: icon(for: item))
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(iconColor(item))
                        )
                    if launcher.isEditing {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                launcher.setHidden(item, true)
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, Color.red)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 7, y: -7)
                    } else if isActive(item) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                    }
                }
                Text(title(for: item))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14)
                          : isHovered ? Color.primary.opacity(0.07)
                          : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.clear,
                                  lineWidth: 1.2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            if hovering, !launcher.isEditing {
                launcher.select(item)
            }
        }
    }

    private var hiddenTray: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.s.launcherAddSection.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            FlowLayoutLite(spacing: 6) {
                ForEach(launcher.hiddenItems) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            launcher.setHidden(item, false)
                        }
                    } label: {
                        Label(title(for: item), systemImage: "plus.circle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous).fill(Color.accentColor.opacity(0.13))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        Text(l10n.s.launcherEditHint)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "keyboard")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(GlobalShortcutRole.quickLauncher.savedShortcut.displayString)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("Esc")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Item metadata

    private func title(for item: QuickLauncherItem) -> String {
        switch item {
        case .keepAwake: return l10n.s.keepAwakeTitle
        case .micMute: return micMute.isMuted ? l10n.s.micUnmuteName : l10n.s.micMuteName
        case .screenOCR: return l10n.s.ocrName
        case .colorPicker: return l10n.s.colorPickerName
        case .clipboard: return FeatureStrings.clipboard(l10n.language).title
        case .windowLayout: return FeatureStrings.windowLayout(l10n.language).title
        case .cleaning: return l10n.s.cleaningMenuItem
        case .homebrew: return l10n.s.homebrewName
        case .media: return l10n.s.mediaName
        case .urlCleaner: return l10n.s.urlCleanerName
        case .uninstaller: return l10n.s.uninstallerName
        }
    }

    private func icon(for item: QuickLauncherItem) -> String {
        switch item {
        case .keepAwake: return keepAwake.isActive ? "bolt.fill" : "bolt"
        case .micMute: return micMute.isMuted ? "mic.slash.fill" : "mic"
        case .screenOCR: return "text.viewfinder"
        case .colorPicker: return "eyedropper"
        case .clipboard: return "doc.on.clipboard"
        case .windowLayout: return "rectangle.3.group"
        case .cleaning: return "keyboard"
        case .homebrew: return "shippingbox"
        case .media: return "photo.on.rectangle.angled"
        case .urlCleaner: return "link"
        case .uninstaller: return "trash"
        }
    }

    private func isActive(_ item: QuickLauncherItem) -> Bool {
        switch item {
        case .keepAwake: return keepAwake.isActive
        case .micMute: return micMute.isMuted
        default: return false
        }
    }

    private func iconColor(_ item: QuickLauncherItem) -> Color {
        if item == .micMute, micMute.isMuted { return .red }
        if isActive(item) { return .accentColor }
        return .primary.opacity(0.85)
    }

    private func iconBackground(_ item: QuickLauncherItem, isSelected: Bool, isHovered: Bool) -> Color {
        if isActive(item) { return Color.accentColor.opacity(0.18) }
        if isSelected || isHovered { return Color.primary.opacity(0.1) }
        return Color.primary.opacity(0.07)
    }
}

/// Minimal wrapping layout for the hidden-item chips.
struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 380
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
