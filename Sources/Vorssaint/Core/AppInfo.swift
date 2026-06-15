import Foundation

/// Static identity of the app, shared by UI, notifications and tooling.
enum AppInfo {
    static let name = "Vorssaint"
    static let copyright = "© 2026 Vorssaint"
    static let repositoryURL = URL(string: "https://github.com/vorssaint/vorssaint-utils")!

    /// The bundle version. The fallback only applies to the bare binary
    /// (e.g. `--selftest`), never the shipped app, which reads its Info.plist.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// True for the local "Vorssaint (Developer)" build (bundle id ends in `.dev`).
    /// It is never published and never auto-updates; all work is tested here first.
    static var isDeveloperBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }
}
