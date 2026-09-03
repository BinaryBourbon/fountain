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
    // The SDK: one call to give an agent a computer, JSON in and JSON out,
    // shaped like its TypeScript, Python and Elixir siblings.
    .library(name: "Fountain", targets: ["Fountain"]),
    // The typed client: Codable models and per-resource namespaces, for
    // applications that bind the API to a UI rather than script it.
    .library(name: "FountainKit", targets: ["FountainKit"]),
  ],
  targets: [
    .target(name: "Fountain", path: "sdk/swift/Sources/Fountain"),
    .testTarget(
      name: "FountainTests", dependencies: ["Fountain"], path: "sdk/swift/Tests/FountainTests"),
    .target(name: "FountainKit", path: "sdk/swift/Sources/FountainKit"),
    .testTarget(
      name: "FountainKitTests", dependencies: ["FountainKit"],
      path: "sdk/swift/Tests/FountainKitTests"),
  ]
)
