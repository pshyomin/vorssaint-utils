import SwiftUI

/// Per-app volume sliders, the mixer macOS never shipped. Shows every app
/// holding an audio connection (a green dot marks the ones playing right now).
/// 100% is untouched passthrough; below it attenuates and above it (up to 200%)
/// boosts, with the slider and percentage turning amber in the boost range.
struct MixerSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var mixer = AppVolumeMixer.shared

    var body: some View {
        PanelSection(.mixer, title: l10n.s.mixerSection) {
            VStack(alignment: .leading, spacing: 8) {
                if !AppVolumeMixer.isSupported {
                    emptyLabel(l10n.s.mixerUnavailable)
                } else if mixer.needsPermission {
                    permissionHint
                } else if mixer.apps.isEmpty {
                    emptyLabel(l10n.s.mixerEmpty)
                } else {
                    ForEach(mixer.apps) { app in
                        MixerRow(app: app)
                    }
                }
            }
            .panelCard()
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }

    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.s.mixerPermissionBody)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(l10n.s.permissionOpenSettings) {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
        }
    }
}

private struct MixerRow: View {
    @ObservedObject private var mixer = AppVolumeMixer.shared
    @ObservedObject private var l10n = L10n.shared
    let app: MixerApp

    /// Amber, matching the panel's dark aesthetic, to flag the boost range.
    private let boostColor = Color(red: 0.96, green: 0.65, blue: 0.16)
    /// Tie the visual state to the displayed percentage, so "amber" and ">100%"
    /// always agree and the reset hides exactly when the row reads 100%.
    private var isBoosting: Bool { (app.volume * 100).rounded() > 100 }
    private var isAtUnity: Bool { (app.volume * 100).rounded() == 100 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: ResponsibleProcess.icon(for: app.ownerPid))
                    .resizable()
                    .frame(width: 18, height: 18)
                if app.isPlaying {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                }
            }

            Text(app.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 86, alignment: .leading)

            Slider(value: volumeBinding, in: 0...AppVolumeMixer.maxVolume)
                .controlSize(.small)
                // Pass an explicit accent (not nil) for the normal state: on the
                // macOS slider, tint(nil) does not reliably clear a previously
                // applied colour, so the bar would stay amber after leaving boost.
                .tint(isBoosting ? boostColor : Color.accentColor)

            HStack(spacing: 2) {
                if isBoosting {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(boostColor)
                }
                Text("\(Int((app.volume * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isBoosting ? boostColor : Color.secondary)
            }
            .frame(width: 42, alignment: .trailing)

            Button {
                mixer.setVolume(1, for: app)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isBoosting ? boostColor : Color.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(l10n.s.mixerResetTooltip)
            .opacity(isAtUnity ? 0 : 1)
            .disabled(isAtUnity)

            Button {
                mixer.toggleMute(app)
            } label: {
                Image(systemName: app.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(app.volume <= 0.001 ? Color.red : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { app.volume },
            set: { mixer.setVolume($0, for: app) }
        )
    }
}
