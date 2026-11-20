// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeXRay",
    // iOS for XRayCore in the iPad app (iPad/XRay.xcodeproj); the app target itself is macOS only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "XRayCore", targets: ["XRayCore"]),
        .executable(name: "S2AClaudeXRay", targets: ["S2AClaudeXRay"]),
    ],
    targets: [
        // Pure Foundation: log parsing, pricing, analytics, insights, export.
        .target(name: "XRayCore"),
        // macOS app: SwiftUI + Swift Charts + MenuBarExtra.
        .executableTarget(name: "S2AClaudeXRay", dependencies: ["XRayCore"]),
        .testTarget(name: "XRayCoreTests", dependencies: ["XRayCore"]),
    ]
)
