import Foundation

/// Facts about this build, read from the app's Info.plist. One place, so the version row and
/// the source links cannot disagree.
enum AppBuild {
    /// `CFBundleShortVersionString`, the App Store version ("1.0"). Empty only when the bundle
    /// carries no version string, which no built app does.
    static var shortVersion: String { string(for: "CFBundleShortVersionString") }

    /// `CFBundleVersion`, the build number ("42"). Empty as above.
    static var buildNumber: String { string(for: "CFBundleVersion") }

    private static func string(for key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? ""
    }
}

/// Links shown in Settings, and the facts behind the engine's license notices.
enum SettingsLinks {
    /// Upstream Stockfish source at the vendored release tag.
    static let stockfishSource = URL(string: "https://github.com/official-stockfish/Stockfish/tree/\(SettingsLegal.stockfishTag)")!

    /// The public repository that holds the complete corresponding source of the app, with one
    /// tag per App Store version (GPLv3 section 6(d); see Packages/ChessEngine/README.md,
    /// "License obligations", and the Source code page of the website).
    static let appSourceRepository = URL(string: "https://github.com/ciscoriordan/chess-best-move")!

    /// The source of exactly this build: the repository at the tag named after the app's
    /// version ("v1.0"), so every release links its own source.
    static var appSource: URL { appSource(shortVersion: AppBuild.shortVersion) }

    /// The Stockfish patch this app applies, inside the published source of this build
    /// (GPLv3 section 5(a); `SettingsLegal.stockfishModification` says what it does).
    static var stockfishPatch: URL { stockfishPatch(shortVersion: AppBuild.shortVersion) }

    /// The support page, which answers the questions Settings > Help does not.
    static let support = URL(string: "https://ciscoriordan.github.io/chessbestmove.app/support.html")!

    /// The privacy policy and terms of use are kept in one place, shared with the paywall.
    static var privacyPolicy: URL { MonetizationLegalLinks.privacyPolicy }
    static var termsOfUse: URL { MonetizationLegalLinks.termsOfUse }

    static let gnuLicenses = URL(string: "https://www.gnu.org/licenses/")!
    static let leelaTrainingData = URL(string: "https://storage.lczero.org/files/training_data")!
    static let openDatabaseLicense = URL(string: "https://opendatacommons.org/licenses/odbl/odbl-10.txt")!

    /// The repository at the tag of `shortVersion`, or the repository itself when there is no
    /// version string to build a tag from.
    static func appSource(shortVersion: String) -> URL {
        sourceURL(filePath: nil, shortVersion: shortVersion)
    }

    /// The patch file at the tag of `shortVersion`, or the repository itself as above.
    static func stockfishPatch(shortVersion: String) -> URL {
        sourceURL(filePath: "Packages/ChessEngine/patches/\(SettingsLegal.stockfishPatchFile)", shortVersion: shortVersion)
    }

    /// A folder or file in the published source at this version's tag. Without a version
    /// string, or with one no URL can be built from, the repository root: it holds every tag.
    private static func sourceURL(filePath: String?, shortVersion: String) -> URL {
        guard !shortVersion.isEmpty else { return appSourceRepository }
        let path = filePath.map { "blob/v\(shortVersion)/\($0)" } ?? "tree/v\(shortVersion)"
        return URL(string: "\(appSourceRepository.absoluteString)/\(path)") ?? appSourceRepository
    }
}

/// Notices required for the app as a whole and for Stockfish (GPLv3), and for the network.
enum SettingsLegal {
    /// The vendored release tag (Packages/ChessEngine/Sources/CStockfish/stockfish/VENDORED_TAG).
    static let stockfishTag = "sf_19"

    /// The one patch in Packages/ChessEngine/patches/, described by `stockfishModification`.
    static let stockfishPatchFile = "0001-optional-no-system-wide-shm.patch"

    // MARK: The app as a whole

    // GPLv3 section 5(d) asks an interactive program to show "Appropriate Legal Notices": the
    // copyright notice, the no-warranty statement, that the user may redistribute under the
    // license, and where to read the license. Stockfish is statically linked into the binary,
    // so this is the notice for the whole app, not only for the engine. The Licenses screen
    // shows all four, with the link to the source of this exact version.

    /// The copyright line for the app as a whole.
    static let appCopyright = "Chess Best Move, Copyright (C) 2026 Motomatic LLC"

    static let appFreeSoftware = """
        Chess Best Move is free software: you can use it, study how it works, change it and \
        share it, changed or unchanged, under the terms of version 3 of the GNU General Public \
        License as published by the Free Software Foundation. The app includes Stockfish, which \
        is under the same license, so the app as a whole is distributed under it.
        """

    static let appNoWarranty = """
        Chess Best Move is distributed in the hope that it will be useful, but WITHOUT ANY \
        WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A \
        PARTICULAR PURPOSE. See the GNU General Public License for more details.
        """

    static let appSourceNotice = """
        The complete source code of this version is published, as the license requires, with a \
        tag for each App Store version.
        """

    // MARK: Stockfish

    /// The copyright line from Stockfish's source files.
    static let stockfishCopyright = "Copyright (C) 2004-2026 The Stockfish developers (see the list of authors)."

    static let stockfishFreeSoftware = """
        Stockfish is free software: you can redistribute it and/or modify it under the terms of the \
        GNU General Public License as published by the Free Software Foundation, either version 3 of \
        the License, or (at your option) any later version.
        """

    static let stockfishNoWarranty = """
        Stockfish is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; \
        without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. \
        See the GNU General Public License for more details.
        """

    /// GPLv3 section 5(a): the modified files and the date of the change
    /// (Packages/ChessEngine/patches/0001-optional-no-system-wide-shm.patch).
    static let stockfishModification = """
        This app contains a modified version of Stockfish 19 (release tag sf_19). On September 13, \
        2026, src/shm.h was changed so that an app embedding Stockfish can turn off its \
        cross-process shared-memory store for the neural network. That store creates files in \
        /tmp, a socket server thread and an exit handler, which do not belong in an app. With the \
        store turned off, the network is kept in ordinary app memory, which is Stockfish's \
        existing fallback. Without the switch, the source behaves exactly like the release.
        """

    /// The training data credit (Stockfish README, "Acknowledgements").
    static let networkCredit = """
        Stockfish's neural network (nn-1a298aa575a0.nnue) is trained on data provided by the \
        Leela Chess Zero project, which is made available under the Open Database License (ODbL).
        """

    /// `deviceName` is "iPhone", "iPad" or "Mac" (`AppDevice.name`).
    static func engineIntroduction(deviceName: String) -> String {
        """
        Chess Best Move analyzes positions with Stockfish, a free and open-source chess engine by \
        the Stockfish developers. It runs on your \(deviceName); nothing is uploaded.
        """
    }
}
