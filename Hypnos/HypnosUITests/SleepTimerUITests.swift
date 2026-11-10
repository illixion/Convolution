/*
 Hypnos UI tests - the sleep timer's settings page

 What a visionOS simulator lets XCUITest do on this page is narrow: it opens
 (through the DEBUG-only `settingsInitialPage` default, because a row below
 the fold of a lazy form can't be scrolled to: swipes are refused), but a tap
 on a row in the form doesn't register, a text field gets no keyboard focus,
 and an unsigned build has no Keychain for a Home Assistant token. So starting
 a timer, adding an accessory and signing in are not driven here. RAVEHome's
 tests cover the actions and their runner, and the devices cover the rest.

 What this does cover is the one thing that must never happen: HomeKit being
 switched on in a build that wasn't signed with the HomeKit capability (every
 simulator build, and the shared sideload profile) must leave the app running.
 */

import RAVEUI
import XCTest

@MainActor
final class SleepTimerUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func openPage(homeKit: Bool = false) -> XCUIApplication {
        // States the flags this page reads, as the launcher's baseline explains.
        let app = AppLauncher.launch(welcome: .dismissed, defaults: [
            "sleepTimer.homeKit.enabled": homeKit ? "1" : "0",
            "settingsInitialPage": "sleepTimer",
        ])
        app.buttons[RAVEA11y.tab("settings")].require("The Settings tab").tap()
        app.anyElement(A11y.SleepTimerUI.start).require("Start Timer")
        return app
    }

    func testAnEmptyPageOffersAStartButtonAndNoCountdown() {
        let app = openPage()
        XCTAssertFalse(app.anyElement(A11y.SleepTimerUI.timeLeft).exists)
        XCTAssertFalse(app.anyElement(A11y.SleepTimerUI.cancel).exists)
        app.anyElement(A11y.SleepTimerUI.addAccessory).require("Add Accessory")
    }

    func testHomeKitWithoutTheCapabilityLeavesTheAppRunning() {
        let app = openPage(homeKit: true)
        // The page activates HomeKit as it appears; give the manager time to
        // answer, or to say nothing, which is what an unentitled build gets.
        sleep(10)
        XCTAssertEqual(app.state, .runningForeground, "The app should still be running")
        app.anyElement(A11y.SleepTimerUI.start).require("The page, still there")
    }
}
