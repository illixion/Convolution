// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GeneratedCaptions",
    platforms: [.iOS(.v26), .macOS(.v26), .tvOS(.v26), .visionOS(.v26)],
    products: [.library(name: "GeneratedCaptions", targets: ["GeneratedCaptions"])],
    dependencies: [
        .package(path: "../../../vergence"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "1b0ed50d686873128a4129b3510ce3914c849bab", traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "GeneratedCaptions", dependencies: [
            .product(name: "VergenceApple", package: "vergence"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .testTarget(name: "GeneratedCaptionsTests", dependencies: ["GeneratedCaptions"]),
    ]
)
