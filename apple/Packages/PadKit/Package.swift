// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "PadKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "PadKit", targets: ["PadKit"])
  ],
  targets: [
    .target(name: "PadKit", swiftSettings: [.treatAllWarnings(as: .error)]),
    .testTarget(
      name: "PadKitTests", dependencies: ["PadKit"],
      swiftSettings: [.treatAllWarnings(as: .error)]),
  ],
  swiftLanguageModes: [.v6]
)
