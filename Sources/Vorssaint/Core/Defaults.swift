import Foundation

/// Every UserDefaults key used by the app, in one place.
enum DefaultsKey {
    static let language = "appLanguage"                   // AppLanguage.rawValue
    static let clamshellPreferred = "clamshellPreferred"  // apply closed-lid mode to every session
    static let onboardingStep = "onboardingStep"          // resume point if onboarding is interrupted
    static let featuresOnboardingVersion = "featuresOnboardingVersion" // last feature-tour version the user saw
    static let defaultDuration = "defaultDurationMinutes" // 0 = indefinite
    static let batteryLimit = "batteryLimitPercent"       // 0 = never
    static let hotkeyEnabled = "hotkeyEnabled"
    static let showCountdown = "showCountdownInMenuBar"
    static let hasOnboarded = "hasOnboarded"
    static let sleepDisabledFlag = "vorssDisabledSleep"   // internal guard for pmset disablesleep
    static let scrollInverterEnabled = "scrollInverterEnabled"
    static let switcherEnabled = "switcherEnabled"
    static let switcherMergeTabs = "switcherMergeTabs"     // collapse an app's same-frame tab windows into one entry
    static let autoCheckUpdates = "autoCheckUpdates"
    static let appVolumes = "appVolumes"                  // [bundle id: 0...1]
    static let finderCutPasteEnabled = "finderCutPasteEnabled"
    static let autoQuitEnabled = "autoQuitEnabled"
    static let autoQuitExceptions = "autoQuitExceptions"  // [bundle id] kept running
    static let shelfEnabled = "shelfEnabled"
    static let shelfShakeToOpen = "shelfShakeToOpen"
}

/// Bump `currentFeatureSet` when a release introduces new features worth a
/// one-time tour. Users who onboarded under an older value are shown the
/// "what's new" pass once, then their stored value catches up.
enum OnboardingInfo {
    static let currentFeatureSet = 1
}

enum Defaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.clamshellPreferred: false,
            DefaultsKey.defaultDuration: 0,
            DefaultsKey.batteryLimit: 10,
            DefaultsKey.hotkeyEnabled: true,
            DefaultsKey.showCountdown: false,
            DefaultsKey.scrollInverterEnabled: false,
            DefaultsKey.switcherEnabled: true,
            DefaultsKey.switcherMergeTabs: false,
            DefaultsKey.autoCheckUpdates: true,
            // Finder never benefits from being "quit" (it just relaunches), so
            // it's excepted out of the box.
            DefaultsKey.autoQuitExceptions: ["com.apple.finder"],
            // When the shelf is on, the shake gesture is on too (still toggleable).
            DefaultsKey.shelfShakeToOpen: true,
        ])
    }
}
