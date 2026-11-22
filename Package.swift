// swift-tools-version:5.9
import PackageDescription

// ScanCore   – komunikace se skenerem (eSCL/AirScan), dělení dávky, pojmenování. Jen Foundation.
// skener-cli – terminálový nástroj pro test spojení a skenování bez aplikace.
// Skener     – aplikace pro macOS (SwiftUI, Vision OCR, PDF).

var targets: [Target] = [
    .target(name: "ScanCore"),
    .executableTarget(name: "skener-cli", dependencies: ["ScanCore"]),
    .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),
]
var products: [Product] = [
    .executable(name: "skener-cli", targets: ["skener-cli"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "Skener", dependencies: ["ScanCore"]))
products.append(.executable(name: "Skener", targets: ["Skener"]))
#endif

let package = Package(
    name: "Skener",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
