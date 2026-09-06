// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyPlay",
    platforms: [.macOS(.v14)],
    // Swift 5 language mode: this is a small, single-threaded orchestration app,
    // and strict concurrency checking would add ceremony without adding safety.
    products: [
        // All orchestration logic lives here, free of any UI. The SwiftUI app and
        // the CLI are both thin front-ends over this one library.
        .library(name: "EasyPlayKit", targets: ["EasyPlayKit"]),
        .executable(name: "easyplay", targets: ["EasyPlayCLI"]),
        .executable(name: "easyplay-tests", targets: ["EasyPlayTests"]),
        .executable(name: "EasyPlayApp", targets: ["EasyPlayApp"]),
    ],
    targets: [
        .target(
            name: "EasyPlayKit",
            resources: [.copy("Resources/Recipes")]
        ),
        .executableTarget(name: "EasyPlayCLI", dependencies: ["EasyPlayKit"]),
        .executableTarget(name: "EasyPlayApp", dependencies: ["EasyPlayKit"]),
        .executableTarget(name: "EasyPlayTests", dependencies: ["EasyPlayKit"]),
    ],
    swiftLanguageModes: [.v5]
)
