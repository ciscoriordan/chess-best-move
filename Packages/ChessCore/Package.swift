// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ChessCore", targets: ["ChessCore"]),
    ],
    targets: [
        .target(name: "ChessCore"),
    ]
)
