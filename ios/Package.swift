// swift-tools-version: 6.0
//
// Zimmer's iOS client, split so that the half worth testing can be tested anywhere.
//
// `ZimmerKit` is Foundation-only — the sign-in protocol, the token lifecycle, the API
// client, the session list rules — and so it builds and tests on Linux CI with no Xcode and
// no Apple Developer Program membership. `ZimmerPlatform` is the Apple-only half (the
// Keychain); every file in it is behind `#if canImport(...)`, so the package still builds
// where those frameworks do not exist and the app target gets real implementations where
// they do.
//
// The app target itself (SwiftUI screens, the CarPlay scene) lives in `App/`, driven by
// `App/Zimmer.xcodeproj`, because an iOS application bundle is not something SwiftPM builds.

import PackageDescription

let package = Package(
    name: "ZimmerKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZimmerKit", targets: ["ZimmerKit"]),
        .library(name: "ZimmerPlatform", targets: ["ZimmerPlatform"]),
    ],
    targets: [
        .target(name: "ZimmerKit"),
        .target(name: "ZimmerPlatform", dependencies: ["ZimmerKit"]),
        .testTarget(name: "ZimmerKitTests", dependencies: ["ZimmerKit"]),
    ]
)
