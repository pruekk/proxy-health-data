// swift-tools-version: 5.9
import PackageDescription

// Unit tests for the app's pure logic. The target compiles the app's own files rather than
// copying them, so there is a single definition and the tests cannot drift from it. Only files
// free of UIKit, SwiftUI and HealthKit belong here — that is what ProxyHealth/Core is for.
//
//   cd ios && swift test
//
// The Xcode project ignores this manifest; it builds from ProxyHealth.xcodeproj as before.
let package = Package(
    name: "ProxyHealthCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ProxyHealthCore", path: "ProxyHealth/Core", sources: ["Trends.swift", "CardFormat.swift", "SyncProgress.swift", "WorkoutRecipe.swift"]),
        .testTarget(name: "ProxyHealthCoreTests", dependencies: ["ProxyHealthCore"], path: "CoreTests/ProxyHealthCoreTests"),
    ]
)
