import SwiftUI

// MARK: - What's new intro (shown to updating users)

struct WhatsNewIntroStep: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.spaceGradient
                VStack(spacing: 10) {
                    BrandMark(width: 96)
                    Text(l10n.s.obWhatsNewTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text(l10n.s.obWhatsNewBody)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 44)
                }
                .padding(.top, 10)
            }
            .frame(height: 224)

            VStack(alignment: .leading, spacing: 14) {
                row("scissors", l10n.s.cutPasteName, l10n.s.cutPasteEnableCaption)
                row("xmark.rectangle", l10n.s.autoQuitName, l10n.s.autoQuitEnableCaption)
                row("trash", l10n.s.uninstallerName, l10n.s.uninstallerEnableCaption)
                row("tray.full", l10n.s.shelfName, l10n.s.shelfEnableCaption)
            }
            .padding(22)
        }
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.spaceGradient)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Scaffold

/// One feature page in onboarding: a hero illustration, the benefit, how to use
/// it, an optional enable toggle and an optional footer (a permission row,
/// etc.). Tools that need no activation (the uninstaller) pass no toggle.
struct ShowcaseScaffold<Hero: View, Footer: View>: View {
    let title: String
    let benefit: String
    let enableLabel: String?
    let enabled: Binding<Bool>?
    let howTo: [HowToRow]
    let onToggle: () -> Void
    let hero: Hero
    let footer: Footer

    init(title: String,
         benefit: String,
         enableLabel: String? = nil,
         enabled: Binding<Bool>? = nil,
         howTo: [HowToRow],
         onToggle: @escaping () -> Void = {},
         @ViewBuilder hero: () -> Hero,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.benefit = benefit
        self.enableLabel = enableLabel
        self.enabled = enabled
        self.howTo = howTo
        self.onToggle = onToggle
        self.hero = hero()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack { Theme.spaceGradient; hero }
                .frame(height: 180)
                .clipped()

            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 19, weight: .bold))
                Text(benefit)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(howTo) { row($0) }
                }
                .padding(.top, 2)

                Spacer(minLength: 4)

                if let enabled, let enableLabel {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(enableLabel, isOn: enabled)
                            .toggleStyle(.switch)
                            .onChange(of: enabled.wrappedValue) { _, _ in onToggle() }
                        footer
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                } else {
                    footer
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func row(_ row: HowToRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let keys = row.keys {
                ShortcutCaps(keys: keys).frame(width: 64, alignment: .leading)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                    .frame(width: 64, alignment: .leading)
            }
            Text(row.text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HowToRow: Identifiable {
    let id = UUID()
    let keys: [String]?
    let text: String
}

// MARK: - Feature steps

struct CutPasteShowcaseStep: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.finderCutPasteEnabled) private var enabled = false

    var body: some View {
        ShowcaseScaffold(
            title: l10n.s.cutPasteName,
            benefit: l10n.s.cutPasteEnableCaption,
            enableLabel: l10n.s.cutPasteEnable,
            enabled: $enabled,
            howTo: [HowToRow(keys: ["⌘", "X"], text: l10n.s.cutPasteStep1),
                    HowToRow(keys: ["⌘", "V"], text: l10n.s.cutPasteStep2)],
            onToggle: { FinderCutPaste.shared.syncWithPreferences() },
            hero: { CutPasteHero() },
            footer: {
                if enabled, !permissions.accessibility { PermissionRow(kind: .accessibility) }
            }
        )
    }
}

struct AutoQuitShowcaseStep: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.autoQuitEnabled) private var enabled = false

    var body: some View {
        ShowcaseScaffold(
            title: l10n.s.autoQuitName,
            benefit: l10n.s.autoQuitEnableCaption,
            enableLabel: l10n.s.autoQuitEnable,
            enabled: $enabled,
            howTo: [HowToRow(keys: nil, text: l10n.s.autoQuitStep1),
                    HowToRow(keys: nil, text: l10n.s.autoQuitStep2)],
            onToggle: { AutoQuitService.shared.syncWithPreferences() },
            hero: { AutoQuitHero() },
            footer: {
                if enabled, !permissions.accessibility { PermissionRow(kind: .accessibility) }
            }
        )
    }
}

struct UninstallerShowcaseStep: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ShowcaseScaffold(
            title: l10n.s.uninstallerName,
            benefit: l10n.s.uninstallerEnableCaption,
            howTo: [HowToRow(keys: nil, text: l10n.s.uninstallerStep1),
                    HowToRow(keys: nil, text: l10n.s.uninstallerStep2),
                    HowToRow(keys: nil, text: l10n.s.uninstallerStep3)],
            hero: { UninstallerHero() },
            footer: { EmptyView() }
        )
    }
}

struct ShelfShowcaseStep: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.shelfEnabled) private var enabled = false

    var body: some View {
        ShowcaseScaffold(
            title: l10n.s.shelfName,
            benefit: l10n.s.shelfEnableCaption,
            enableLabel: l10n.s.shelfEnable,
            enabled: $enabled,
            howTo: [HowToRow(keys: ["⌃", "⌥", "⌘", "D"], text: l10n.s.shelfStep1),
                    HowToRow(keys: nil, text: l10n.s.shelfStep2),
                    HowToRow(keys: nil, text: l10n.s.shelfStep3)],
            onToggle: { ShelfService.shared.syncWithPreferences() },
            hero: { ShelfHero() },
            footer: {
                Label(l10n.s.shelfNoPermission, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        )
    }
}

// MARK: - Hero illustrations

private struct HeroKey: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 20, minHeight: 22)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.32)))
    }
}

private struct HeroKeys: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) { ForEach(keys, id: \.self) { HeroKey(label: $0) } }
    }
}

private struct CutPasteHero: View {
    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 9) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 42))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "scissors")
                            .font(.system(size: 14, weight: .bold))
                            .padding(3)
                            .background(Circle().fill(Color.orange))
                            .offset(x: 8, y: -6)
                    }
                HeroKeys(keys: ["⌘", "X"])
            }
            Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).opacity(0.7)
            VStack(spacing: 9) {
                Image(systemName: "folder.fill").font(.system(size: 42))
                HeroKeys(keys: ["⌘", "V"])
            }
        }
        .foregroundStyle(.white)
    }
}

private struct AutoQuitHero: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "macwindow")
                .font(.system(size: 50, weight: .light))
                .overlay(alignment: .topLeading) {
                    Circle().fill(Color.red).frame(width: 9, height: 9).padding(8)
                }
            Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).opacity(0.7)
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40))
        }
        .foregroundStyle(.white)
    }
}

private struct UninstallerHero: View {
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .frame(width: 56, height: 56)
                Image(systemName: "app.fill").font(.system(size: 30))
            }
            VStack(spacing: 5) {
                Image(systemName: "doc.fill").font(.system(size: 12)).opacity(0.8)
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).opacity(0.7)
            }
            Image(systemName: "trash.fill").font(.system(size: 40))
        }
        .foregroundStyle(.white)
    }
}

private struct ShelfHero: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                chip("doc.fill")
                chip("photo.fill")
                chip("link")
            }
            Image(systemName: "tray.full.fill").font(.system(size: 40))
        }
        .foregroundStyle(.white)
    }

    private func chip(_ symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.16))
                .frame(width: 38, height: 38)
            Image(systemName: symbol).font(.system(size: 16))
        }
    }
}
