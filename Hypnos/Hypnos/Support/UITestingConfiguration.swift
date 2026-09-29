/*
 Hypnos - UI testing configuration

 The app-side half of the XCUITest harness: launch arguments that put persisted
 state into a known shape before anything reads it.

 A UI test cannot reach into the process it drives, so every piece of state a
 test depends on has to be settable from outside. UserDefaults' own argument
 domain very nearly does this — `-someKey 0` in `launchArguments` is picked up
 by `bool(forKey:)` automatically — but only for the typed accessors, and this
 app reads several flags as `object(forKey:) as? Bool` precisely so it can tell
 "never set" from "set to false". That distinction is what decides whether the
 welcome flow appears at all, so the overrides are applied explicitly here
 instead of being left to a bridging coincidence.

 **DEBUG only.** Nothing in this file exists in a release build, which is what
 keeps a shipping app from having launch arguments that rewrite the user's
 settings. XCUITest runs against the Debug configuration, so the tests are
 unaffected.
 */

#if DEBUG

import DebugTrace
import Foundation

@MainActor
enum UITestingConfiguration {

    /// Applies any launch-argument overrides. Call once, before the first read
    /// of UserDefaults — `HypnosApp.init` does, ahead of building
    /// `AppModel`, because `AppModel.init` is where most defaults are read.
    static func applyIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(A11y.LaunchArgument.enabled) else { return }

        // Routed through `AppLogger.app` so the lines show up in the in-app
        // console like everything else, and so the subsystem cannot drift from
        // the rest of the app during the rename.
        let logger = AppLogger.app

        if arguments.contains(A11y.LaunchArgument.resetDefaults) {
            resetDefaults(logger: logger)
        }

        for override in overrides(in: arguments) {
            UserDefaults.standard.set(override.value, forKey: override.key)
            logger.notice("UI testing: set \(override.key, privacy: .public)")
        }
    }

    /// Best-effort wipe of everything this app has persisted.
    ///
    /// **Best-effort is the operative word, and it is why the tests declare the
    /// state they depend on rather than trusting this.** On the simulator
    /// `cfprefsd` will serve a value that is in neither the persistent domain
    /// nor the on-disk plist: measured directly, `persistentDomain(forName:)`
    /// came back empty and listed no `enableRemoteViewer` key, no plist on the
    /// device contained the string at all, and `bool(forKey:)` on the very next
    /// line still returned `true` — a value written by a test run minutes
    /// earlier. Nothing this side of the process boundary removes it, so the
    /// baseline in `AppLauncher` sets every flag a test reads explicitly.
    /// Removing each key as well as the domain is still worth doing: it clears
    /// everything that *is* reachable, which is most of it.
    private static func resetDefaults(logger: DebugLogger) {
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier else { return }
        let persisted = defaults.persistentDomain(forName: domain) ?? [:]
        for key in persisted.keys {
            defaults.removeObject(forKey: key)
        }
        defaults.removePersistentDomain(forName: domain)
        logger.notice("UI testing: cleared \(persisted.count, privacy: .public) persisted defaults")
    }

    /// Every `-UITestDefault key=value` pair, in the order given.
    private static func overrides(in arguments: [String]) -> [(key: String, value: Any)] {
        var result: [(key: String, value: Any)] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            defer { index = arguments.index(after: index) }
            guard arguments[index] == A11y.LaunchArgument.setDefault else { continue }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { break }
            // Split on the first `=` only, so a value may contain one (a URL
            // query, a base64 tail).
            let pair = arguments[valueIndex]
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<separator])
            let raw = String(pair[pair.index(after: separator)...])
            guard !key.isEmpty else { continue }
            result.append((key, parse(raw)))
            index = valueIndex
        }
        return result
    }

    /// `1`/`0`/`true`/`false` become booleans, a bare number becomes a number,
    /// anything else stays a string. Booleans are the common case and have to
    /// arrive as booleans: a `"0"` string read back through
    /// `object(forKey:) as? Bool` is nil, which reads as "never set".
    private static func parse(_ raw: String) -> Any {
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default:
            if let integer = Int(raw) { return integer }
            if let double = Double(raw) { return double }
            return raw
        }
    }
}

#endif
