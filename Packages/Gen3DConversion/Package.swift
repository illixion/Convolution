// swift-tools-version: 6.0
import Foundation
import PackageDescription

// GLB -> USDZ for Generated 3D (HYPNOS_GEN3D), behind one small seam.
//
// AnythingUSDZKit is a sibling checkout (~/Projects/AnythingUSDZ) that is still work in
// progress and unpublished, so a clone of this repo has no such folder. The kit is a
// dependency of this package only when that folder is there; without it the package
// still builds and `Gen3DConverter.isAvailable` is false (Generated 3D then reports that
// it can't convert). Set HYPNOS_WITHOUT_ANYTHINGUSDZ=1 to leave it out on a machine that
// has it (a submission build). SwiftPM re-evaluates this manifest when it changes or the
// package is re-resolved, so after adding or removing the checkout, reset package caches.
let kitPath = "../../../AnythingUSDZ/Packages/AnythingUSDZKit"
let manifestDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let kitExists = FileManager.default.fileExists(
    atPath: manifestDirectory.appendingPathComponent(kitPath + "/Package.swift").path)
let withKit = kitExists && ProcessInfo.processInfo.environment["HYPNOS_WITHOUT_ANYTHINGUSDZ"] == nil

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
