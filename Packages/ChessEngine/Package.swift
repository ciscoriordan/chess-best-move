// swift-tools-version: 6.2
import PackageDescription

// Compiler flags for the vendored Stockfish sources (see README.md, "Build flags").
// Architecture switches (NEON, popcount, 64-bit) live in
// Sources/CStockfish/bridge/sf_build_config.h because SwiftPM cannot vary flags by
// CPU architecture.
//
// All configurations: -O3 -funroll-loops as in Stockfish's Makefile. Optimization is
// forced even in Debug, because an unoptimized engine searches about ten times fewer
// nodes and would make Debug builds of the app misleading. libc++ hardening is turned
// off for the same reason (Xcode's Debug configuration enables its debug mode, which
// bounds-checks every std::array access in the search).
let stockfishFlags: [String] = [
    "-include", "sf_build_config.h",
    "-O3",
    "-funroll-loops",
    "-U_LIBCPP_HARDENING_MODE",
    "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE",
    "-Wno-unused-parameter",
    "-Wno-shorten-64-to-32",
]

// Release only: full link-time optimization, as in Stockfish's Makefile. Debug skips it
// because LTO moves Stockfish's optimization into every link of the app (about 10 s).
// Debug also keeps Stockfish's assertions; Release defines NDEBUG.
let stockfishReleaseFlags: [String] = [
    "-flto=full",
]

let package = Package(
    name: "ChessEngine",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ChessEngine", targets: ["ChessEngine"]),
    ],
    targets: [
        .target(
            name: "CStockfish",
            path: "Sources/CStockfish",
            exclude: [
                "stockfish/Copying.txt",
                "stockfish/AUTHORS",
                "stockfish/README.md",
                "stockfish/VENDORED_TAG",
                "stockfish/src/main.cpp",
                "stockfish/src/Makefile",
                "stockfish/src/universal",
                "stockfish/src/incbin/UNLICENCE",
            ],
            sources: [
                "bridge",
                "stockfish/src",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("bridge"),
                .headerSearchPath("stockfish/src"),
                .define("NNUE_EMBEDDING_OFF"),
                .define("STOCKFISH_NO_SYSTEM_WIDE_SHM"),
                .define("NDEBUG", .when(configuration: .release)),
                .unsafeFlags(stockfishFlags),
                .unsafeFlags(stockfishReleaseFlags, .when(configuration: .release)),
            ]
        ),
        .target(
            name: "ChessEngine",
            dependencies: ["CStockfish"],
            path: "Sources/ChessEngine",
            resources: [
                // The NNUE network(s) fetched by scripts/fetch-nets.sh. The file name is
                // looked up at runtime from the compiled Stockfish sources. The folder
                // must not be called "Resources": codesign rejects an iOS resource
                // bundle with a top-level Resources directory.
                .copy("NNUE"),
                // The privacy manifest for the required-reason API Stockfish calls: `fstat`
                // (file timestamp category) in syzygy/tbprobe.cpp. An app that links this
                // package declares the same reason in its own manifest.
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
