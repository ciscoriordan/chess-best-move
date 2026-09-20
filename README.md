# Chess Best Move

Copyright (C) 2026 Motomatic LLC

This is the source code of Chess Best Move, an iOS app that analyzes a chess position from a
screenshot. You take a screenshot of a position, import it into the app, and the app finds the
board in the image, recognizes every piece with a Core ML model that runs on the device, works
out which way the board is turned and whose turn it is, and searches the position with
Stockfish 19 compiled into the app. It draws the best move as an arrow over your own board
image and shows the move in standard algebraic notation with the evaluation. Everything runs on
the device and no image is sent anywhere.

Website: <https://ciscoriordan.github.io/chessbestmove.app/>

Chess Best Move is free software, licensed under the GNU General Public License version 3. See
[License](#license) below.

## License

Chess Best Move is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version.

Chess Best Move is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
the GNU General Public License for more details.

The full license text is in [`LICENSE`](LICENSE).

The app includes the Stockfish chess engine, which the Stockfish developers license under
GPLv3 or, at your option, any later version. Stockfish is statically linked into the app
binary, so the app as distributed is one combined work covered by GPLv3.

### Additional term under GPLv3 section 7(e)

For material in this repository whose copyright Motomatic LLC holds, one additional term
applies, as GPLv3 section 7(e) permits:

> Motomatic LLC does not grant rights under trademark law to use the name "Chess Best Move" or
> the app icon.

GPLv3 still lets you use, change and share that material as a copyrighted work, and you may
state accurately that a work is based on Chess Best Move. If you publish a changed version,
give it your own name and your own icon.

### Versions and tags

Each App Store version has a tag named `v` followed by the version number the App Store shows,
which is the app's `CFBundleShortVersionString` (`MARKETING_VERSION` in `project.yml`), without
the build number: `v1.0` for the version the app shows as "1.0 (3)" under Settings > About >
Version. A tag holds the Corresponding Source of that exact App Store build, as GPLv3
section 1 defines it. Tags are never removed, so the source of an older version stays
available. The tip of the default branch is the work in progress and may be ahead of every
released version.

## What this repository contains

Everything needed to build the app, and nothing else. Development material that the build does
not need is not here: the tests, the test images, the program and the images used to train the
recognition model, and internal design notes.

```
project.yml                 XcodeGen specification; ChessBestMove.xcodeproj is generated from
                            it and is not committed
LICENSE                     the GNU General Public License version 3
scripts/
  check-release-placeholders.sh   the app target's first build phase (see "Build phases")
App/
  Info.plist                generated from project.yml by xcodegen; not committed
  Sources/                  the app's Swift code, one module, in folders by area:
                              App/           entry point, navigation, settings, shared copy
                              DesignSystem/  color, type and spacing tokens, shared components
                              Monetization/  StoreKit 2 store, analysis credits, purchase screens
                              Capture/       image import, recognition, check position, editor
                              Analysis/      engine control, best-move arrow, result screen
                              Settings/      settings and license screens
                              Intents/       the "Find Best Move" App Shortcut
  Resources/
    Assets.xcassets/        app icon and the two named colors
    Fonts/                  the bundled chess-glyph typeface and its license text
    Settings/               Stockfish's license text and author list, shown in the app
    PrivacyInfo.xcprivacy   the app's privacy manifest
  Scripts/
    sync-stockfish-notices.sh      copies Stockfish's notices into App/Resources/Settings
Packages/
  ChessCore/                squares, pieces, positions, FEN, legal moves, algebraic notation
  ChessEngine/              Stockfish 19 compiled in process, with a Swift API (see its README)
  ChessVision/              board detection, the piece classifier, orientation, side to move
```

The recognition model is here in both forms: the compiled model the app loads
(`Packages/ChessVision/Sources/ChessVision/Model/PieceClassifier.mlmodelc`, the only file of
that package that ships) and the Core ML model package it was compiled from
(`Packages/ChessVision/ModelSource/PieceClassifier.mlpackage`). Both hold the same weights.
See `Packages/ChessVision/ModelSource/README.md` for the model's inputs and outputs and for
how to compile the package again.

The model was trained on rendered screenshots, not on photographs, and some of the board and
piece art used to render them is published under licenses that ask for credit. `NOTICE.md` at
the root of this repository names those sets, their authors and their licenses. None of that art
is in this repository or in the app: only the trained weights ship.

Stockfish's neural network is the file
`Packages/ChessEngine/Sources/ChessEngine/NNUE/nn-1a298aa575a0.nnue` (98,511,183 bytes,
SHA-256 `1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2`). It is committed as
an ordinary git object. If it is ever missing from your checkout, run
`Packages/ChessEngine/scripts/fetch-nets.sh`, which downloads the network the vendored engine
asks for and refuses any file whose SHA-256 does not match the pinned hash.

## Building the app

You need a Mac with:

- **Xcode 27.0** or later, with an iOS Simulator runtime. The app is built and tested with
  Xcode 27.0 and the iOS 26.5 and iOS 27.0 simulator runtimes.
- **XcodeGen 2.45** or later: `brew install xcodegen`. The Xcode project is generated from
  `project.yml` and is not committed, so this step is required.

Then:

```sh
xcodegen generate
open ChessBestMove.xcodeproj
```

Choose the `ChessBestMove` scheme and a simulator or a device, and run. Run `xcodegen generate`
again only after changing `project.yml`; files added or removed under `App/Sources` and
`App/Resources` are picked up by the next build, because those are Xcode synchronized folders.

From the command line, without signing:

```sh
xcodegen generate
xcodebuild build -project ChessBestMove.xcodeproj -scheme ChessBestMove \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO
```

To build a signed app for a device, replace `DEVELOPMENT_TEAM` in `project.yml` with your own
Apple Developer team identifier and change `PRODUCT_BUNDLE_IDENTIFIER` to a bundle identifier
you own, then generate the project again. The in-app purchases will not load under a different
bundle identifier; the rest of the app works.

The Swift packages also build and run on their own:

```sh
cd Packages/ChessCore   && swift build
cd Packages/ChessEngine && swift build
cd Packages/ChessVision && swift build
```

Notes on the build:

- The first build compiles the whole Stockfish source tree, which takes a few minutes. Release
  builds also link it with full link-time optimization.
- Stockfish is compiled with `-O3` in every configuration, including Debug. An unoptimized
  engine searches about ten times fewer nodes, which would make Debug builds misleading.
  `Packages/ChessVision` is optimized in every configuration for the same reason.
- The app's deployment target is iOS 26.0, for iPhone and iPad.
- `Packages/ChessEngine/README.md` documents every engine build flag and why it has the value
  it has, how the Swift API calls Stockfish, and what the engine needs in memory. Its "Tests"
  section describes that package's test suite, which is development material and is not part of
  this repository.

### Build phases

The app target has one script phase, `scripts/check-release-placeholders.sh`. It searches
`App/Sources` and `App/Info.plist` for URLs that must not reach a release: the reserved example
domains, a URL whose text contains `TODO`, and a link to Apple's standard End User License
Agreement, whose usage rules conflict with GPLv3 section 10. The script's own comment lists the
exact patterns. It then runs `scripts/check-release-source-tag.sh`, which builds the two source
links the app shows from the version being built and asks whether they answer, because those
links are assembled at run time and no pattern can see whether the tag behind them exists; with
no network it cannot ask, and it then lets the archive through. Both run only when Xcode
archives or installs (`ACTION=install`), so ordinary Debug and Release builds are never blocked
by them, and `CHESS_BEST_MOVE_SOURCE_TAG_CHECK=0` turns the second one off. The target turns
Xcode's user script sandbox off for that phase, because a sandboxed phase is not allowed to
read the source files it has to check.

If you build a changed version of this app for distribution, point
`SettingsLinks.appSourceRepository` in `App/Sources/Settings/SettingsLegal.swift` at your own
published source; that check then asks about your repository and your tag, not this one.

## Stockfish

Chess Best Move searches positions with **Stockfish 19** (release tag `sf_19`, published
2026-09-05). The engine source is vendored under
`Packages/ChessEngine/Sources/CStockfish/stockfish/`, downloaded and verified by
`Packages/ChessEngine/scripts/vendor-stockfish.sh`.

> Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)
>
> Stockfish is free software: you can redistribute it and/or modify it under the terms of the
> GNU General Public License as published by the Free Software Foundation, either version 3 of
> the License, or (at your option) any later version.
>
> Stockfish is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
> without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
> See the GNU General Public License for more details.

Stockfish's own notices are kept with the source: `Copying.txt` (the GPLv3 text) and `AUTHORS`
in `Packages/ChessEngine/Sources/CStockfish/stockfish/`. The same two files are in
`App/Resources/Settings/`, where the app's Licenses screen reads them.

- The Stockfish project: <https://stockfishchess.org/>
- Stockfish at tag `sf_19`:
  <https://github.com/official-stockfish/Stockfish/tree/sf_19>

### Modification of Stockfish (GPLv3 section 5(a) notice)

Stockfish as vendored here is modified. On **2026-09-13**, `src/shm.h` was changed so that an
application embedding Stockfish can define `STOCKFISH_NO_SYSTEM_WIDE_SHM` to turn off
Stockfish's cross-process shared-memory store for the neural network. On Apple platforms that
store creates a file in `/tmp`, a Unix-domain socket server thread per copy of the network, and
an exit handler. With the define, the network is kept in ordinary process memory, which is
Stockfish's existing fallback path. Without the define, the source behaves exactly like the
release. This app defines it (`Packages/ChessEngine/Package.swift`).

The change itself is the patch
`Packages/ChessEngine/patches/0001-optional-no-system-wide-shm.patch`, which
`Packages/ChessEngine/scripts/vendor-stockfish.sh` applies to the downloaded release. There are
no other changes to Stockfish's source. The section "Local modifications (GPLv3 section 5a
notice)" in `Packages/ChessEngine/README.md` describes it as well.

### The neural network

Stockfish's neural networks are trained on data provided by the Leela Chess Zero project, which
makes that data available under the Open Database License (ODbL).

- Leela Chess Zero training data: <https://storage.lczero.org/files/training_data>
- Open Database License 1.0: <https://opendatacommons.org/licenses/odbl/odbl-10.txt>

## Fonts

The app sets its text in the system faces, SF Pro and SF Mono. They belong to the operating
system, are reached through `UIFont`, and are not copied into the app or redistributed here.

One typeface is bundled, under the SIL Open Font License 1.1, unmodified. Its license text is in
`App/Resources/Fonts/`.

| Typeface | Copyright | License text |
| --- | --- | --- |
| Noto Sans Symbols 2 | Copyright 2022 The Noto Project Authors | `NotoSansSymbols2-OFL.txt` |

Noto Sans Symbols 2 supplies the chess piece glyphs the app draws on its board diagrams, which is
the only reason any font is bundled: the system font has no chess pieces.

## Attribution

`NOTICE.md` lists the board and piece art whose licenses ask for credit, with authors and
licenses, and says how it was used. It is generated from this project's asset record rather than
written by hand, so it cannot drift from the art the weights were actually fitted on.

## Support

The app's support page, privacy policy and terms of use are on the website:
<https://ciscoriordan.github.io/chessbestmove.app/>. For questions about the app itself,
<support@motomatic.com>.

This repository is published because GPLv3 requires it. It is not a collaborative project and
pull requests are not reviewed. You are free to fork it and do what GPLv3 permits.
