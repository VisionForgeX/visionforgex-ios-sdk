// swift-tools-version:5.9
import PackageDescription

// VfxCore: settings, pacing, price floors, events, one full-screen slot. Foundation only, no ad SDK.
// VisionForgeX: what apps add. UIKit, Google Mobile Ads (the Google engine) and Google's consent SDK.
let package = Package(
    name: "VisionForgeX",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "VisionForgeX", targets: ["VisionForgeX"]),
        .library(name: "VfxCore", targets: ["VfxCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", .upToNextMajor(from: "11.13.0")),
        .package(url: "https://github.com/googleads/swift-package-manager-google-user-messaging-platform.git", .upToNextMajor(from: "2.7.0")),
    ],
    targets: [
        .target(name: "VfxCore"),
        .target(
            name: "VisionForgeX",
            dependencies: [
                "VfxCore",
                .product(name: "GoogleMobileAds", package: "swift-package-manager-google-mobile-ads"),
                .product(name: "GoogleUserMessagingPlatform", package: "swift-package-manager-google-user-messaging-platform"),
            ]
        ),
        .testTarget(name: "VfxCoreTests", dependencies: ["VfxCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
