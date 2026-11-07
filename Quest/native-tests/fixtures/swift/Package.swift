// swift-tools-version: 6.2
// Writes the Quest's VGAT test tracks with VergenceCore itself, and prints a
// real track's sums for the comparison in ../../run.sh. Vergence is the
// sibling checkout, as the Apple app references it.
import PackageDescription

let package = Package(
    name: "MakeFixtures",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Vergence", path: "../../../../../vergence")],
    targets: [
        .executableTarget(name: "MakeFixtures", dependencies: [.product(name: "VergenceCore", package: "Vergence")]),
    ]
)
