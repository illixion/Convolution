import RAVEUI
import XCTest

/// Seed Documents/Photos/hud-fixture.png in the test app's container before
/// running. A generated colour card is sufficient; no server or Photos grant.
@MainActor
final class PhotoHUDUITests: XCTestCase {
    func testLocalPhotoEntersHUDWithItsControls() throws {
        continueAfterFailure = false
        let app = AppLauncher.launch(welcome: .dismissed, defaults: [
            "librarySource": "local", "autoHideDelay": "0", "openMediaInNewWindows": "1"
        ])
        app.buttons[RAVEA11y.tab("albums")].require("Albums").tap()
        let photo = app.staticTexts["hud-fixture"]
        try XCTSkipUnless(photo.waitForExistence(timeout: 10), "Seed the generated local HUD photo fixture first")
        photo.tap()
        let enter = app.buttons["rave.hud.enter"]
        enter.require("Photo HUD control", timeout: 20).tap()
        app.sliders["HUD size"].require("HUD size control", timeout: 15)
        app.buttons["rave.hud.return"].require("HUD return control")
        XCTAssertTrue(app.staticTexts["Showing in HUD"].exists)
        app.terminate()
    }
}
