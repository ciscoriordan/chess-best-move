// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChessCore",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "ChessCore", targets: ["ChessCore"]),
    ],
    targets: [
        .target(name: "ChessCore"),
    ]
)
