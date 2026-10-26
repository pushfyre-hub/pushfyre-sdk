// swift-tools-version:5.7
//
// Swift Package Manager requires this manifest at the repository root.
// PushFyre stays on iOS 13. PushFyreLiveActivity is a second library for iOS 16.2
// and does not raise the minimum of the main library.
//
import PackageDescription

let package = Package(
    name: "PushFyre",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "PushFyre", targets: ["PushFyre"]),
        .library(name: "PushFyreLiveActivity", targets: ["PushFyreLiveActivity"])
    ],
    targets: [
        .target(name: "PushFyre", path: "sdk-ios/Sources/PushFyre"),
        .target(
            name: "PushFyreLiveActivity",
            dependencies: ["PushFyre"],
            path: "sdk-ios/Sources/PushFyreLiveActivity"
        )
    ]
)
