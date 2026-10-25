// swift-tools-version: 6.2
import PackageDescription

// A Hypnos-local package, deliberately not part of RAVESDK: nothing here is
// shared with the other RAVE apps, and RAVESDK's scope is the code that is.
//
// It turns a Matroska or WebM file into fragmented-MP4 HLS on demand: the
// file's Cues become the segment index, each segment's clusters are read and
// muxed into a media segment when the player asks for it, and the playlists
// are plain text. No re-encoding, no ffmpeg, no temp files. The app serves the
// result from a loopback HTTP server (`Hypnos/Services/MatroskaRemux/`), so
// AVFoundation plays MKV and WebM the way it plays any HLS stream.
//
// It is a package rather than app-target sources for the same reason as
// NextcloudMedia: none of it touches a UI framework (Foundation only, I/O
// behind `ByteSource`), so it builds and tests natively on the host in
// seconds. EBML edge cases, sample-entry bytes and timing are far quicker to
// get right against `swift test` and the committed fixtures than through a
// simulator. The test target also opens what it writes with AVFoundation on
// the Mac, which is the check that matters.
//
// macOS is a first-class platform here; visionOS, iOS and tvOS are declared
// because the app links the library on each (an undeclared platform gets
// SwiftPM's ancient default deployment floor, not an excluded one).
let package = Package(
    name: "MatroskaRemux",
    platforms: [.macOS(.v14), .visionOS(.v26), .iOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "MatroskaRemux", targets: ["MatroskaRemux"]),
    ],
    targets: [
        .target(name: "MatroskaRemux"),
        .testTarget(
            name: "MatroskaRemuxTests",
            dependencies: ["MatroskaRemux"],
            resources: [.copy("Fixtures")]
        ),
        // Writes a file's HLS (playlists, init and media segments) to a
        // folder, for checking a remux with ffmpeg or a browser without the
        // app. Not a product, so the app never builds it.
        .executableTarget(name: "mkvremux", dependencies: ["MatroskaRemux"]),
    ]
)
