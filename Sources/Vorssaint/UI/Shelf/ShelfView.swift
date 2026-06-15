import SwiftUI
import UniformTypeIdentifiers

/// Contents of the floating shelf panel: a header (a move handle plus actions)
/// and the item tiles. Dropping onto the card adds items; the tiles themselves
/// are AppKit, so they can drag several selected items out at once.
struct ShelfView: View {
    @EnvironmentObject private var shelf: ShelfService
    @ObservedObject private var l10n = L10n.shared
    @State private var targeted = false

    private static let dropTypes: [UTType] = [.fileURL, .image, .url, .text, .plainText]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            tiles
            if !shelf.items.isEmpty {
                Text(l10n.s.shelfHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(HUDBackdrop(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.12),
                              lineWidth: targeted ? 2 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
        .animation(.easeOut(duration: 0.18), value: shelf.items)
        .onDrop(of: Self.dropTypes, isTargeted: $targeted) { providers in
            shelf.accept(providers: providers)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            // Drag this region to move the panel; the tiles below stay free to
            // start item drags.
            HStack(spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(WindowMoveHandle())

            if !shelf.items.isEmpty {
                Button(action: trashAction) {
                    Image(systemName: shelf.selection.isEmpty ? "trash" : "trash.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(shelf.selection.isEmpty ? l10n.s.shelfClearAll : l10n.s.shelfRemoveSelected)
            }
            Button { shelf.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        shelf.selection.isEmpty
            ? l10n.s.shelfTitle
            : String(format: l10n.s.shelfSelectedFormat, shelf.selection.count)
    }

    @ViewBuilder
    private var tiles: some View {
        if shelf.items.isEmpty {
            emptyState
        } else {
            ShelfTilesView(items: shelf.items, selection: shelf.selection)
                .frame(height: 92)
        }
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(.secondary.opacity(0.4))
            .frame(height: 92)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 18)).foregroundStyle(.secondary)
                    Text(l10n.s.shelfEmpty).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            )
    }

    private func trashAction() {
        if shelf.selection.isEmpty {
            shelf.clear()
        } else {
            shelf.removeItems(Array(shelf.selection))
        }
    }
}
