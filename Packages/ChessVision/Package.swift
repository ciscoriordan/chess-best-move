// swift-tools-version: 6.0
import PackageDescription

// The image-processing loops (board detection, cell statistics, board resampling) are
// about 20 times slower without optimization, which makes Debug builds of the app
// misleadingly slow. Optimize this module in every configuration.
let optimizeAlways: [SwiftSetting] = [
    .unsafeFlags(["-O"], .when(configuration: .debug)),
]

let package = Package(
    name: "ChessVision",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ChessVision", targets: ["ChessVision"]),
    ],
    dependencies: [
        .package(path: "../ChessCore"),
    ],
    targets: [
        .target(
            name: "ChessVision",
            dependencies: ["ChessCore"],
            resources: [
                // Model/ holds only PieceClassifier.mlmodelc, the compiled Core ML model, copied as
                // is so `swift build` needs no Core ML code generation. The Core ML model package
                // it was built from is in ModelSource/, outside the target, and does not ship.
                .copy("Model"),
            ],
            swiftSettings: optimizeAlways
        ),
    ]
)
