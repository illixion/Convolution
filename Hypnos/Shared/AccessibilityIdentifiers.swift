/*
 Hypnos - Accessibility identifiers

 **This file is a member of both the app target and `HypnosUITests`.**

 That is unusual here — every other source file is picked up automatically by
 the synchronized folder group, and this one is referenced explicitly in
 `project.pbxproj` instead — and it is the point of the file. A UI test target
 shares no module with the app it drives, so identifiers otherwise have to be
 written out twice, and the copy in the test target silently rots the first time
 the app's is edited. One file in two targets is the only arrangement where the
 identifier a test matches on and the identifier the view carries cannot drift.

 Shared components (the tab bar, the window inventory) form their own
 identifiers in `RAVEA11y`, which both targets reach through RAVEUI. What lives
 here is only what is specific to this app.

 Anything a UI test needs to find gets an identifier rather than being matched
 on its label: labels are display copy, and the app is mid-rename.
 */

import Foundation

enum A11y {

    /// The tab bar's library-switch dropdown (Photos/Stash/Local).
    /// Explicit rather than the default `RAVEA11y.tabAction(systemImage)`
    /// derivation, because the icon — and so the derived identifier — changes
    /// with whichever library is current.
    static let librarySwitch = "librarySwitch"

    /// One row inside the library-switch dropdown, keyed by the source's
    /// `LibrarySource.rawValue` — this file is a member of both targets, but
    /// `LibrarySource` itself lives only in the app target, so the parameter
    /// is the raw string rather than the type.
    static func librarySwitchOption(_ sourceRawValue: String) -> String {
        "librarySwitch.\(sourceRawValue)"
    }

    /// Albums tab.
    enum Albums {
        /// The Local library's folder browser, as opposed to the Photos/Stash
        /// container grid — the thing a test checks for to know which one is
        /// on screen.
        static let localBrowser = "albums.localBrowser"
    }

    /// Video window.
    enum Video {
        /// The stalled/failed card shown in place of a video with no picture.
        static let loadStatus = "video.loadStatus"
    }

    /// First-run flow.
    enum Welcome {
        static let panel = "welcome.panel"

        // Footer
        static let skip = "welcome.skip"
        static let back = "welcome.back"
        static let advance = "welcome.continue"
        /// The last page's dismiss button, whichever of the two wordings it is
        /// currently showing.
        static let finish = "welcome.finish"

        // Intro page
        static let sampleImage = "welcome.sample.image"
        static let sampleConvert = "welcome.sample.convert"
        static let sampleModePicker = "welcome.sample.mode"
        static let sampleProgress = "welcome.sample.progress"

        // Sources page
        static let photosCard = "welcome.source.photos"
        static let photosAllow = "welcome.source.photos.allow"
        static let serverCard = "welcome.source.server"
        static let serverURLField = "welcome.source.server.url"
        static let serverKeyField = "welcome.source.server.key"
        static let serverConnect = "welcome.source.server.connect"
        static let backupCard = "welcome.source.backup"
        static let backupChoose = "welcome.source.backup.choose"
    }

    /// Launch arguments the UI tests use to put the app into a known state.
    /// Read by `UITestingConfiguration`, which is compiled into DEBUG builds
    /// only — a release build ignores every one of these.
    enum LaunchArgument {
        /// Required for any of the others to be honoured, so a stray argument
        /// can never reconfigure a real launch.
        static let enabled = "-UITest"
        /// Wipe the app's persistent defaults before anything reads them.
        static let resetDefaults = "-UITestResetDefaults"
        /// `-UITestDefault key=value`, repeatable. Values are parsed as a
        /// property list fragment, so `1`/`0` arrive as numbers and everything
        /// else as a string.
        static let setDefault = "-UITestDefault"
    }
}
