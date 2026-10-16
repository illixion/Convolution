/*
 Hypnos UI tests - the shared tab bar and window inventory

 Both of these views live in RAVESDK's `RAVEUI`, not in this app, and this file
 is where they get driven for real. A Swift package cannot host XCUITest —
 there is no UI-testing product type, and the harness needs an app to attach to
 — so the package's own `RAVEUITests` covers the arithmetic and bookkeeping and
 the views are exercised here, in the app that embeds them. Anything that fails
 in this file is a bug report against the SDK, not against Hypnos.

 The identifiers come from `RAVEA11y`, which both the SDK and this target link,
 so there is nothing to keep in sync by hand: a tab is `rave.tab.<name>` and
 this app passes its enum case names, which survive the display-copy rename the
 titles will not.
 */

import RAVEUI
import XCTest

@MainActor
final class SharedTabBarUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Tabs whose visibility is not conditional on a developer setting.
    private let alwaysVisibleTabs = ["pictures", "videos", "albums", "filters", "windows", "settings"]

    func testEveryUnconditionalTabIsOffered() {
        let app = AppLauncher.launch(welcome: .dismissed)
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab")

        for tab in alwaysVisibleTabs {
            XCTAssertTrue(
                app.buttons[RAVEA11y.tab(tab)].exists,
                "The \(tab) tab should be in the bar"
            )
        }
    }

    /// Console is a developer tab, and hiding it is what keeps the bar down to
    /// a usable width for everyone else.
    func testDeveloperTabsAreHiddenUntilEnabled() {
        let app = AppLauncher.launch(welcome: .dismissed)
        app.buttons[RAVEA11y.tab("pictures")].require("The Pictures tab")

        XCTAssertFalse(app.buttons[RAVEA11y.tab("console")].exists, "Console should be hidden by default")
    }

    func testDeveloperTabsAppearWhenTheSettingIsOn() {
        let app = AppLauncher.launch(
            welcome: .dismissed,
            defaults: ["showDebugConsole": "1"]
        )
        app.buttons[RAVEA11y.tab("console")].require("The Console tab, with the setting on")
    }

    func testSwitchingTabsChangesWhatIsShown() {
        let app = AppLauncher.launch(welcome: .dismissed)
        let settings = app.buttons[RAVEA11y.tab("settings")].require("The Settings tab")

        settings.tap()

        // The tab bar labels only the *selected* tab, so the label appearing is
        // itself the evidence the selection took.
        XCTAssertTrue(
            app.staticTexts["Settings"].waits(),
            "Selecting Settings should reveal its label in the bar and its content below"
        )
    }

    // MARK: - Window inventory

    /// The Windows tab lists every window *except* the one it is displayed in,
    /// so with a single window open it is legitimately empty — and that empty
    /// state is load-bearing: it is what a user sees when nothing has been
    /// popped out, and it has to explain itself rather than look broken.
    func testTheWindowInventoryExplainsItselfWhenEmpty() {
        let app = AppLauncher.launch(welcome: .dismissed)
        app.buttons[RAVEA11y.tab("windows")].require("The Windows tab").tap()

        XCTAssertTrue(
            app.staticTexts["No Other Windows"].waits(),
            "An empty inventory should say so rather than show a blank list"
        )
    }

    /// The bulk controls are the app's own contribution to RAVEUI's inventory,
    /// and both have to be dead when there is nothing to act on — Close All
    /// reaches underneath SwiftUI to destroy scene sessions, so an enabled
    /// button with no targets is a button that can only misfire.
    func testBulkWindowActionsAreDisabledWithNothingToActOn() {
        let app = AppLauncher.launch(welcome: .dismissed)
        app.buttons[RAVEA11y.tab("windows")].require("The Windows tab").tap()

        let closeAll = app.buttons["Close All Windows"].require("The Close All button")
        XCTAssertFalse(closeAll.isEnabled, "Close All should be disabled with only this window open")
        XCTAssertFalse(
            app.buttons["Hide All Windows"].isEnabled,
            "Hide All should be disabled with only this window open"
        )
    }

    // A window actually *listed* in the inventory — and so Summon, the recycle
    // path, and `RAVEA11y.windowSummon`/`windowClose` — needs a pop-out, and
    // every pop-out needs media or a server. Seeding those is out of reach from
    // inside the test process: it is `simctl addmedia` plus
    // `simctl privacy grant photos`, which belong to whatever runs the tests.
    // That is the next piece of harness to build, not a gap in the SDK.
}
