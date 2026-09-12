// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "macos-image",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "MacOSImageCore", targets: ["MacOSImageCore"]),
    .executable(name: "macos-image", targets: ["MacOSImageCLI"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      exact: "1.8.2"
    )
  ],
  targets: [
    .target(name: "MacOSImageCore"),
    .executableTarget(
      name: "MacOSImageCLI",
      dependencies: [
        "MacOSImageCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "MacOSImageCoreTests",
      dependencies: ["MacOSImageCore"]
    ),
  ]
)
