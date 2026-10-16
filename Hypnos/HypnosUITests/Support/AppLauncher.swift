/*
 Hypnos UI tests - launching the app in a known state

 Every test starts from a wiped defaults domain and states the flags it depends
 on, because a UI test that inherits the simulator's leftover state passes or
 fails for reasons that have nothing to do with the code. The arguments are
 read by the app's `UITestingConfiguration`; the names are shared, not copied
 (see `AccessibilityIdentifiers.swift`, which is a member of both targets).

 Everything else here is waiting. XCUITest's default `exists` is a snapshot and
 an app that is still launching, or a view still mid-transition, has not drawn
 the element yet — so the helpers wait rather than assert, and the assertion is
 about what was found.
 */

import XCTest

@MainActor
enum AppLauncher {

    enum Welcome {
        /// Fresh install: the first-run flow is up.
        case shown
        /// Already been through it: straight to the gallery.
        case dismissed
    }

    /// Flags whose value changes what these tests see, given an explicit value
    /// on every launch.
    ///
    /// Wiping the defaults domain is not enough on its own: the simulator's
    /// `cfprefsd` serves values that survive both `removeObject(forKey:)` and
    /// `removePersistentDomain(forName:)` — a developer-only tab appearing in a
    /// freshly reset app, left on by a test run minutes earlier, is what
    /// established that. Stating the value is also just better test design; a
    /// test that reads a flag should say what it expects that flag to be.
    ///
    /// A caller's own `defaults` override any of these.
    private static let baseline: [String: String] = [
        "showDebugConsole": "0",
    ]

    /// Launches the app with a wiped defaults domain and the given state.
    ///
    /// - Parameters:
    ///   - welcome: whether the first-run flow should be presented.
    ///   - defaults: extra UserDefaults overrides as `key: value`; values are
    ///     parsed app-side, so `"1"`/`"0"` arrive as booleans.
    static func launch(
        welcome: Welcome,
        defaults: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            A11y.LaunchArgument.enabled,
            A11y.LaunchArgument.resetDefaults,
        ]

        var overrides = baseline
        overrides["hasCompletedWelcome"] = welcome == .shown ? "0" : "1"
        overrides.merge(defaults) { _, caller in caller }
        // Sorted so a failing run is reproducible from the logged arguments.
        for (key, value) in overrides.sorted(by: { $0.key < $1.key }) {
            app.launchArguments += [A11y.LaunchArgument.setDefault, "\(key)=\(value)"]
        }

        app.launch()
        return app
    }
}

// MARK: - Finding

extension XCUIApplication {

    /// Any element carrying this identifier, whatever type it resolved to.
    ///
    /// SwiftUI decides how a view maps onto the accessibility tree, and the
    /// answer moves between OS versions — a segmented `Picker` may or may not
    /// arrive as a `segmentedControl`, a container with an identifier as an
    /// `other`. Matching on type as well as identifier is a second thing to be
    /// wrong about, so tests that only need "the thing with this identifier"
    /// ask for exactly that.
    func anyElement(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }
}

// MARK: - Waiting

extension XCUIElement {

    /// Waits for the element and returns whether it arrived. Use when either
    /// outcome is legitimate; use `require` when it is not.
    @MainActor
    func waits(timeout: TimeInterval = 10) -> Bool {
        waitForExistence(timeout: timeout)
    }

    /// Waits for the element, failing the test with a useful message if it
    /// never appears.
    @MainActor
    @discardableResult
    func require(
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            waitForExistence(timeout: timeout),
            "\(what) never appeared (identifier: \(identifier))",
            file: file, line: line
        )
        return self
    }

    /// Waits for the element to go away, failing with a useful message if it
    /// does not. A dismissal is as much a result as an appearance, and `!exists`
    /// read immediately after a tap is usually just early.
    @MainActor
    func requireToVanish(
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitForNonExistence(timeout: timeout),
            "\(what) was still there after \(Int(timeout))s (identifier: \(identifier))",
            file: file, line: line
        )
    }
}
