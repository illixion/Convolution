// swift-tools-version: 6.2
import PackageDescription

// FFmpeg's DTS and TrueHD/MLP audio decoders and Dolby Vision RPU reader and
// writer, for the sideload edition.
//
// The decoders live in HypnosFFmpeg.framework, built by
// `scripts/build-ffmpeg-decoders.sh` into `HypnosFFmpeg.xcframework` beside
// this file (gitignored). Nothing links against it: this package's Swift
// wrapper loads the framework with dlopen when asked, and only a sideload
// build embeds it (the app's "Embed FFmpeg decoders" build phase, under
// HYPNOS_FFMPEG). So the package always builds, in any checkout, and an App
// Store build carries no FFmpeg code whatever is on the machine that made it
// (CLAUDE.md, "An App Store build never does Dolby processing itself"). A
// static library, tried first, was linked into every build: SwiftPM links a
// package target's objects whole, and even Release kept all of FFmpeg.
//
// Licence: FFmpeg's own LGPL-2.1+ decoders, as a separately loaded dynamic
// framework, in a sideload IPA whose complete source is public (MIT).

let package = Package(
    name: "FFmpegDecoders",
    platforms: [.macOS(.v14), .visionOS(.v26), .iOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "FFmpegDecoders", targets: ["FFmpegDecoders"]),
    ],
    targets: [
        // The shim's header alone, for its types (`hyp_ff_dovi_rpu`): nothing
        // in it is compiled here, and its functions are looked up with dlsym.
        .target(name: "CFFmpegShim", path: "Shim", exclude: ["shim.c"], publicHeadersPath: "."),
        .target(name: "FFmpegDecoders", dependencies: ["CFFmpegShim"]),
        .testTarget(name: "FFmpegDecodersTests", dependencies: ["FFmpegDecoders"]),
    ]
)
