// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "computer-agent",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .executable(name: "ComputerAgent", targets: ["ComputerAgent"]),
    ],
    targets: [
        // Everything headless. No AppKit, no SwiftUI, no UI of any kind.
        .target(name: "Harness"),

        // The application. Owns the HUD and the cursor overlay.
        .executableTarget(name: "ComputerAgent", dependencies: ["Harness"]),
    ]
)
