// swift-tools-version:5.7
//
// Swift Package Manager requires this manifest at the repository root, so it lives here
// rather than beside the sources in sdk-ios/. The iOS SDK sources stay under
// sdk-ios/Sources/PushFyre; everything else in this repository is the push platform
// itself (API, worker, frontend, Android SDK) and is not part of the package.
//
import PackageDescription

let package = Package(
    name: "PushFyre",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "PushFyre", targets: ["PushFyre"])
    ],
    targets: [
        .target(name: "PushFyre", path: "sdk-ios/Sources/PushFyre")
    ]
)
