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
    ]
)
