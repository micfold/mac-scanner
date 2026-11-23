// swift-tools-version: 6.0
import PackageDescription

// Module map
//
//   PrinterKit   Printer & scanner protocols (IPP, eSCL), batch splitting, naming.
//                Foundation only — builds and is tested on macOS and Linux.
//   AppFeature   The macOS app: feature models (@Observable) + SwiftUI views,
//                talking to the device through protocol-based services.
//   Skener       App entry point (composition root).
//   skener-cli   Command-line tool for testing a printer/scanner.
//   snapshots    Renders the app's screens with sample data to PNG (used by CI).

var products: [Product] = [
  .library(name: "PrinterKit", targets: ["PrinterKit"]),
  .executable(name: "skener-cli", targets: ["skener-cli"]),
]

var targets: [Target] = [
  .target(name: "PrinterKit"),
  .executableTarget(name: "skener-cli", dependencies: ["PrinterKit"]),
  .testTarget(name: "PrinterKitTests", dependencies: ["PrinterKit"]),
]

#if os(macOS)
  products += [.executable(name: "Skener", targets: ["Skener"])]
  targets += [
    .target(name: "AppFeature", dependencies: ["PrinterKit"]),
    .executableTarget(name: "Skener", dependencies: ["AppFeature"]),
    .executableTarget(name: "snapshots", dependencies: ["AppFeature"]),
    .testTarget(name: "AppFeatureTests", dependencies: ["AppFeature"]),
  ]
#endif

let package = Package(
  name: "Skener",
  platforms: [.macOS(.v14)],
  products: products,
  targets: targets,
  swiftLanguageModes: [.v6]
)
