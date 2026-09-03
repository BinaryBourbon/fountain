// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "Fountain",
  platforms: [
    .macOS(.v12),
    .iOS(.v15),
    .tvOS(.v15),
    .watchOS(.v8),
  ],
  products: [
    .library(name: "Fountain", targets: ["Fountain"])
  ],
  targets: [
    .target(name: "Fountain", path: "sdk/swift/Sources/Fountain"),
    .testTarget(
      name: "FountainTests", dependencies: ["Fountain"], path: "sdk/swift/Tests/FountainTests"),
  ]
)
