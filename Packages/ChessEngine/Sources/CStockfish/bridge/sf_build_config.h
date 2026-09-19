// Build configuration for the vendored Stockfish sources.
//
// Package.swift force-includes this header (`-include sf_build_config.h`) into
// every C++ translation unit of the CStockfish target. It replaces the
// architecture switches that Stockfish's Makefile would pass on the command line,
// because SwiftPM cannot vary compiler flags per CPU architecture and a single
// build can contain both an arm64 and an x86_64 slice (the "generic iOS
// Simulator" destination builds both).
//
// arm64 (iPhone, iPad, Apple silicon Mac, arm64 simulator): the equivalent of
// Stockfish's `ARCH=armv8`: 64-bit, hardware popcount, NEON (ARMv8 level).
//
// NEON dot product (`ARCH=armv8-dotprod` / `apple-silicon`, USE_NEON_DOTPROD) is
// deliberately NOT enabled. The app's deployment target is iOS 26, which no
// longer runs on the Apple A12 iPhones, but the app is universal and iPadOS 26
// still runs on A12 and A12X iPads (iPad 8th generation, iPad mini 5th
// generation, iPad Air 3rd generation, iPad Pro 11-inch 1st generation, iPad Pro
// 12.9-inch 3rd generation). LLVM's CPU tables list dot product (ARMv8.4
// DotProd) for apple-a13 and later but not for apple-a12, and iOS gives no way
// to install a per-CPU slice. Enabling it would make those iPads crash with an
// illegal-instruction signal on the first evaluation.
//
// x86_64 (iOS Simulator on Intel Macs only): portable 64-bit build, no SIMD
// intrinsics. It only has to be correct, not fast.

#ifndef SF_BUILD_CONFIG_H
#define SF_BUILD_CONFIG_H

#if defined(__aarch64__) || defined(__arm64__)
    #define IS_64BIT
    #define USE_POPCNT
    #define USE_NEON 8
#elif defined(__x86_64__)
    #define IS_64BIT
#endif

// Networks are loaded from the app bundle at runtime instead of being embedded
// with incbin (Package.swift also defines this; repeated here for tools that
// only see this header).
#ifndef NNUE_EMBEDDING_OFF
    #define NNUE_EMBEDDING_OFF
#endif

// Do not create /tmp/stockfish-<uid>, a Unix socket server thread and an atexit
// handler to share the network between Stockfish processes (see patches/).
#ifndef STOCKFISH_NO_SYSTEM_WIDE_SHM
    #define STOCKFISH_NO_SYSTEM_WIDE_SHM
#endif

#endif  // SF_BUILD_CONFIG_H
