/*
 Hypnos UI tests - the video window's player ornament

 Needs the disposable dev Stash (`scripts/dev-stash.sh up`, port 9998); the
 test skips when it isn't running. The visionOS simulator can't reliably play
 network video, but the transport renders as soon as a duration is known,
 which is all the layout under test needs.

 The ornament is RAVEUI's `RAVEPlayerControls` with the app's button row as
 its accessories. An ornament proposes no width, so the control has to size
 itself; when it didn't, the whole bar collapsed to ~237 points, mute sat on
 top of the forward button and Info/Share/More were scrolled out of sight.
 */

import RAVEUI
import XCTest

@MainActor
final class VideoWindowUITests: XCTestCase {

    private static let devStash = "http://127.0.0.1:9998"

    override func setUp() {
        continueAfterFailure = false
    }

    func testPlayerOrnamentShowsTheWholeTransportAndButtonRow() throws {
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
        let mute = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'speaker.'")).firstMatch
            .require("The mute button")

        XCTAssertGreaterThanOrEqual(slider.frame.width, 400, "The timeline collapsed: \(slider.frame)")
        XCTAssertFalse(mute.frame.intersects(forward.frame),
                       "Mute \(mute.frame) overlaps Forward \(forward.frame)")

        // Every app button must be laid out in the bar rather than scrolled
        // past either end of it: the bar's padding starts at 0, and mute sits
        // at its trailing edge.
        for label in ["Grid View", "Info", "Share", "More"] {
            let button = app.buttons[label].require("The \(label) button")
            XCTAssertTrue(button.isHittable, "\(label) isn't reachable")
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0, "\(label) \(button.frame) is scrolled off the leading edge")
            XCTAssertLessThanOrEqual(button.frame.maxX, mute.frame.maxX + 1,
                                     "\(label) \(button.frame) is past the bar's trailing edge \(mute.frame.maxX)")
        }
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
