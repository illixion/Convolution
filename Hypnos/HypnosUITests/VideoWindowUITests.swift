/*
 Hypnos UI tests - the video window's control strip

 Needs the disposable dev Stash (`scripts/dev-stash.sh up`, port 9998); the
 test skips when it isn't running. The visionOS simulator can't reliably play
 network video, but the transport renders as soon as a duration is known,
 which is all the layout under test needs.

 The strip is RAVEUI's `RAVEPlayerControls` (`.strip`) with the app's buttons
 as its accessories: the timeline across the top, then the transport, volume
 and the buttons in one row, the least needed of them in More when the strip
 is too narrow for all. An ornament proposes no width; when the control
 didn't size itself, the whole bar collapsed to ~237 points, mute sat on top
 of the forward button and buttons were scrolled out of sight.
 */

import RAVEUI
import XCTest

@MainActor
final class VideoWindowUITests: XCTestCase {

    private static let devStash = "http://127.0.0.1:9998"

    override func setUp() {
        continueAfterFailure = false
    }

    func testControlStripKeepsItsEssentialsOnOneRowAndTheRestInMore() throws {
        try XCTSkipUnless(Self.devStashIsUp(), "Dev Stash isn't running: scripts/dev-stash.sh up")

        let app = AppLauncher.launch(
            welcome: .dismissed,
            // 0 = never auto-hide, so the ornament can't vanish mid-query.
            defaults: ["stashServerURL": Self.devStash, "librarySource": "stash", "autoHideDelay": "0"]
        )
        app.buttons[RAVEA11y.tab("videos")].require("The Videos tab").tap()
        app.images.matching(identifier: "play.circle.fill").firstMatch
            .require("A video thumbnail", timeout: 20).tap()

        let slider = app.sliders["Playback position"].require("The timeline", timeout: 20)
        let forward = app.buttons["Forward 10 seconds"].require("Forward 10 seconds")
        let volume = app.buttons["Volume"].require("The volume button")
        let viewMode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View Mode'")).firstMatch
            .require("The View Mode badge, kept on the strip at any width")
        let more = app.buttons["More"].require("More")

        // The timeline has a row of its own, as wide as the strip.
        XCTAssertGreaterThanOrEqual(slider.frame.width, 500, "The timeline collapsed: \(slider.frame)")
        XCTAssertFalse(volume.frame.intersects(forward.frame),
                       "Volume \(volume.frame) overlaps Forward \(forward.frame)")
        for (label, button) in [("Forward", forward), ("Volume", volume), ("View Mode", viewMode), ("More", more)] {
            XCTAssertTrue(button.isHittable, "\(label) isn't reachable")
            XCTAssertGreaterThan(button.frame.midY, slider.frame.maxY, "\(label) \(button.frame) isn't below the timeline")
            XCTAssertGreaterThanOrEqual(button.frame.minX, slider.frame.minX - 80,
                                        "\(label) \(button.frame) is past the strip's leading edge")
            XCTAssertLessThanOrEqual(button.frame.maxX, slider.frame.maxX + 120,
                                     "\(label) \(button.frame) is past the strip's trailing edge")
        }

        // Share is on the strip when it has room, else in More; never lost.
        more.tap()
        app.buttons["Share"].require("Share, on the strip or in More")
    }

    /// A choice on the bar (Speed here, like Quality, Subtitles and View Mode)
    /// is a popover: one row carries the checkmark, and a pick applies,
    /// closes it and shows on the badge. As a Menu, tapping its button again
    /// to dismiss it never reported closing and left the picture dimmed, and
    /// every row drew a checkmark. (The open popover hides the bar from the
    /// accessibility tree, so the second tap itself can't be driven here.)
    func testBarChoiceOpensClosesAndPicks() throws {
        try XCTSkipUnless(Self.devStashIsUp(), "Dev Stash isn't running: scripts/dev-stash.sh up")

        let app = AppLauncher.launch(
            welcome: .dismissed,
            defaults: ["stashServerURL": Self.devStash, "librarySource": "stash", "autoHideDelay": "0"]
        )
        app.buttons[RAVEA11y.tab("videos")].require("The Videos tab").tap()
        app.images.matching(identifier: "play.circle.fill").firstMatch
            .require("A video thumbnail", timeout: 20).tap()
        _ = app.sliders["Playback position"].require("The timeline", timeout: 20)

        let speed = app.buttons["Speed: 1×"].require("The Speed badge")
        let normal = app.buttons["Normal (1×)"]
        // The simulator may write the decimal with a comma.
        let faster = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "1[,.]5×")).firstMatch

        speed.tap()
        _ = normal.require("The Speed rows")
        XCTAssertEqual(app.images.matching(identifier: "checkmark").count, 1,
                       "Only the speed in force carries a checkmark")

        faster.tap()
        XCTAssertTrue(faster.waitForNonExistence(timeout: 3), "A pick closes the popover")
        _ = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "Speed: 1[,.]5×")).firstMatch
            .require("The badge shows the pick").tap()
        app.buttons["Normal (1×)"].require("The Speed rows reopen").tap()
        _ = app.buttons["Speed: 1×"].require("Back to normal speed")
    }

    private static func devStashIsUp() -> Bool {
        var request = URLRequest(url: URL(string: "\(devStash)/graphql")!, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"query":"{findScenes{count}}"}"#.utf8)
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return ok
    }
}
