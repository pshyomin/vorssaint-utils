import AppKit
import Combine

/// Checks GitHub Releases for a newer version and, when asked, downloads the
/// release DMG and installs it over the running app. Self-update for an app
/// distributed outside the App Store, with no third-party framework.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    private let repository = "vorssaint/vorssaint-utils"
    private var downloadURL: URL?
    private var refreshTimer: Timer?
    private var notifiedVersion: String?   // last release we posted a notification for

    private init() {}

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.autoCheckUpdates) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.autoCheckUpdates)
            configureAutomaticChecks()
        }
    }

    // MARK: - Scheduling

    /// Called at launch: checks shortly after start and then daily, if enabled.
    func startAutomaticChecks() {
        // The local dev build never auto-updates, but can simulate the
        // "update available" UI via the `simulateUpdate` default, for testing.
        if AppInfo.isDeveloperBuild {
            if UserDefaults.standard.bool(forKey: DefaultsKey.simulateUpdate) {
                state = .available(version: "9.9.9")
            }
            return
        }
        configureAutomaticChecks()
        if autoCheckEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.check(manual: false)
            }
        }
    }

    private func configureAutomaticChecks() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard autoCheckEnabled else { return }
        // Hourly (was daily). Combined with the activate / panel-open checks, a new
        // release surfaces within the hour instead of up to a day later.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
        timer.tolerance = 60 * 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Check

    func check(manual: Bool) {
        if AppInfo.isDeveloperBuild {
            // No real update target; reflect the simulation default so the
            // notification UI can be exercised locally.
            state = UserDefaults.standard.bool(forKey: DefaultsKey.simulateUpdate)
                ? .available(version: "9.9.9") : .upToDate
            lastChecked = Date()
            return
        }
        if case .checking = state { return }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Vorssaint/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.lastChecked = Date()
                guard let data, error == nil,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    self.state = .failed(error?.localizedDescription ?? "—")
                    return
                }
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                let asset = release.assets.first { $0.name.hasSuffix(".dmg") }
                self.downloadURL = asset?.browserDownloadURL

                if Self.isNewer(latest, than: AppInfo.version), self.downloadURL != nil {
                    self.state = .available(version: latest)
                    // Notify once per distinct release, not on every hourly re-check.
                    if !manual, latest != self.notifiedVersion {
                        self.notifiedVersion = latest
                        let s = L10n.shared.s
                        Notifier.post(title: s.updateNotifyTitle,
                                      body: "\(s.updateAvailablePrefix) \(latest)")
                    }
                } else {
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    /// Re-checks only if the last check is stale — called when the app reactivates
    /// or the panel opens, so a new release surfaces promptly without hammering the
    /// API. The hourly timer is the floor; this makes it feel immediate.
    func checkIfStale(maxAge: TimeInterval = 15 * 60) {
        if AppInfo.isDeveloperBuild { return }
        guard autoCheckEnabled else { return }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        if let last = lastChecked, Date().timeIntervalSince(last) < maxAge { return }
        check(manual: false)
    }

    // MARK: - Download & install

    func downloadAndInstall() {
        if AppInfo.isDeveloperBuild { return }  // never replace the local dev build over itself
        guard let downloadURL else { return }
        // Remember the offer so a failed download restores it (the user can retry)
        // instead of dropping to a dead .failed state that hides the update and
        // blocks checkIfStale for 15 min.
        let offered: String?
        if case let .available(version) = state { offered = version } else { offered = nil }
        state = .downloading

        URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, _, error in
            guard let self else { return }
            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    self.state = offered.map { State.available(version: $0) } ?? .failed(error?.localizedDescription ?? "—")
                }
                return
            }
            // Move out of the URL session's scratch space before handing off.
            let dmgURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Vorssaint-update.dmg")
            try? FileManager.default.removeItem(at: dmgURL)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dmgURL)
            } catch {
                DispatchQueue.main.async {
                    self.state = offered.map { State.available(version: $0) } ?? .failed(error.localizedDescription)
                }
                return
            }
            DispatchQueue.main.async {
                self.state = .installing
                self.launchInstaller(dmgPath: dmgURL.path)
            }
        }.resume()
    }

    /// Hands the swap to a detached shell script: it waits for this process to
    /// quit, mounts the DMG, replaces the bundle, clears quarantine and
    /// relaunches. Running it outside the app means the bundle can be replaced
    /// safely while we exit.
    private func launchInstaller(dmgPath: String) {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        APP="$1"; DMG="$2"; PID="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        MNT="$(/usr/bin/mktemp -d)"
        /usr/bin/hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MNT" || { /usr/bin/open "$APP"; exit 1; }
        SRC="$(/usr/bin/find "$MNT" -maxdepth 1 -name '*.app' -print -quit)"
        LAUNCH="$APP"
        if [ -n "$SRC" ]; then
            # Install under the name the DMG ships, in the same folder. A rebrand
            # changes the bundle filename, so this renames it on disk too; a plain
            # update keeps the same name and replaces it in place.
            DEST="$(/usr/bin/dirname "$APP")/$(/usr/bin/basename "$SRC")"
            # Stage the full copy FIRST; the old app is only removed after the
            # copy completed, so a failure mid-copy never leaves the user with no
            # app at all.
            STAGE="$DEST.update-new"
            /bin/rm -rf "$STAGE"
            if /usr/bin/ditto "$SRC" "$STAGE"; then
                # Clear ALL xattrs (quarantine + FinderInfo the DMG round-trip
                # adds): FinderInfo breaks strict signature verification.
                /usr/bin/xattr -cr "$STAGE" 2>/dev/null
                if /bin/rm -rf "$DEST" && /bin/mv "$STAGE" "$DEST"; then
                    LAUNCH="$DEST"
                    # If the bundle was renamed, remove the old-named one. The
                    # bundle id is unchanged, so macOS keeps every granted
                    # permission for the new bundle.
                    [ "$DEST" != "$APP" ] && /bin/rm -rf "$APP"
                fi
            fi
            /bin/rm -rf "$STAGE"
        fi
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null
        /bin/rm -f "$DMG"
        /usr/bin/open "$LAUNCH"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-update.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptURL.path, appPath, dmgPath, "\(pid)"]
        do {
            try task.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        // Quit so the installer can replace the bundle; it relaunches us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Version compare

    /// True when `latest` is a higher semantic version than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let l = parts(latest), c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }
}

// MARK: - GitHub API shapes

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
