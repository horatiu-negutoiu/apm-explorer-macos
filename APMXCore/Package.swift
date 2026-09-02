// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "APMXCore",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "APMXCore", targets: ["APMXCore"])
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "APMXCore",
      dependencies: ["CSQLite"]
    ),
    .testTarget(
      name: "APMXCoreTests",
      dependencies: ["APMXCore", "CSQLite"],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
