// swift-tools-version: 6.0
import Foundation
import PackageDescription

// GLB -> USDZ for Generated 3D (HYPNOS_GEN3D), behind one small seam.
//
// AnythingUSDZKit is a sibling checkout (~/Projects/AnythingUSDZ) that is still work in
// progress and unpublished, so it is only linked in a Generated 3D build: the one with
// GEN3D_CONDITION=HYPNOS_GEN3D, the same flag that compiles the feature in. A manifest
// cannot see Xcode build settings, only the environment, so the sideload build exports
// the flag (scripts/build-signing.conf) as well as passing it to xcodebuild. CI and a clean
// clone have neither: the package builds without the kit and `Gen3DConverter.isAvailable`
// is false. SwiftPM re-evaluates this manifest when it changes or the package is
// re-resolved, so after flipping the flag, reset package caches.
let kitPath = "../../../AnythingUSDZ/Packages/AnythingUSDZKit"
let manifestDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let kitExists = FileManager.default.fileExists(
    atPath: manifestDirectory.appendingPathComponent(kitPath + "/Package.swift").path)
let withKit = kitExists && ProcessInfo.processInfo.environment["GEN3D_CONDITION"] == "HYPNOS_GEN3D"

let package = Package(
    name: "Gen3DConversion",
    platforms: [.visionOS(.v2), .iOS(.v17), .macOS(.v14), .tvOS(.v17)],
    products: [.library(name: "Gen3DConversion", targets: ["Gen3DConversion"])],
    dependencies: withKit ? [.package(path: kitPath)] : [],
    targets: [
        .target(
            name: "Gen3DConversion",
            dependencies: withKit ? [.product(name: "AnythingUSDZKit", package: "AnythingUSDZKit")] : [],
            swiftSettings: withKit ? [.define("HAS_ANYTHINGUSDZ")] : []
        )
    ]
)
