// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "open-agent",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .executable(name: "open-agent", targets: ["OpenAgent"]),
    ],
    targets: [
        // Everything headless. No AppKit, no SwiftUI, no UI of any kind.
        .target(name: "Harness"),

        // The CLI. Owns the overlay, the approval sheet, and stdout.
        .executableTarget(name: "OpenAgent", dependencies: ["Harness"]),

        // Live probes against the real APIs. Deliberately NOT part of `swift test`:
        // a test suite that needs an API key and a browser is a test suite people
        // stop running — SPEC.md § Testing Strategy.
        .executableTarget(name: "Probe", dependencies: ["Harness"]),

        // Unit + fixture tests. swift-testing, not XCTest.
        .testTarget(name: "SafetyTests", dependencies: ["Harness"]),
        .testTarget(
      name: "CandidateFilterTests", dependencies: ["Harness"],
      // The S7 fixtures are real captures, so the assertion is about real pages
      // rather than about the comparison operator.
      resources: [.copy("Fixtures")]
    ),
        .testTarget(name: "JudgmentTests", dependencies: ["Harness"]),
        .testTarget(name: "LoopTests", dependencies: ["Harness"]),
    .testTarget(name: "PerceptionTests", dependencies: ["Harness"]),
    ]
)
