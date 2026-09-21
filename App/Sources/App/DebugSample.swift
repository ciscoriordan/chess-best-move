#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// DEBUG-only sample screenshot for the end-to-end smoke path and UI tests.
///
/// The image is `App/DebugResources/DebugSampleScreenshot.png`, a copy of one rendered
/// screenshot from the synthetic test set. It is excluded from Release builds
/// (`EXCLUDED_SOURCE_FILE_NAMES` in project.yml), because synthetic screenshots are rendered
/// with third-party board art that must never ship.
enum DebugSample {
    /// Launch argument that imports the sample as soon as the app starts.
    static let autorunArgument = "-autorunSample"

    /// The position in the sample (White at the bottom, White to move).
    static let fen = "rnbq1rk1/ppp1ppbp/3p1np1/8/2PPP3/2N2N2/PP3PPP/R1BQKB1R w KQ - 2 6"

    static func load() -> ImportedImage? {
        guard let url = Bundle.main.url(forResource: "DebugSampleScreenshot", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return ImportedImage(image: image, source: .debugSample)
    }
}

/// DEBUG-only launch options for screenshots and UI tests. Pass them as launch arguments,
/// for example `xcrun simctl launch <device> com.motomatic.chessbestmove -debugSheet settings`.
enum DebugLaunchOptions {
    /// `-autorunSample`: import the sample screenshot at launch.
    static var autorunSample: Bool {
        ProcessInfo.processInfo.arguments.contains(DebugSample.autorunArgument)
    }

    /// `-debugSheet paywall|downsell|settings|shortcutSetup`: present that sheet at launch.
    static var sheet: String? {
        UserDefaults.standard.string(forKey: "debugSheet")
    }

    /// `-debugEditor YES`: present the position editor with the start position at launch.
    static var editor: Bool {
        UserDefaults.standard.bool(forKey: "debugEditor")
    }

    /// `-debugGallery YES`: show the design system gallery instead of the app.
    static var gallery: Bool {
        UserDefaults.standard.bool(forKey: "debugGallery")
    }

    /// `-resetStateForUITests YES`: start as a fresh install. Deletes every Keychain item the
    /// app writes - the credit records and the launch-cohort verdict, all of which survive
    /// reinstalling - and the app's saved preferences, before any service is created. For UI
    /// tests that exercise the real Keychain and StoreKit.
    static var resetState: Bool {
        UserDefaults.standard.bool(forKey: "resetStateForUITests")
    }

    /// `-debugRecognitionDelay <seconds>`: keeps the Recognizing screen up for at least that
    /// long, so screenshots can capture it.
    static var recognitionDelay: Duration? {
        let seconds = UserDefaults.standard.double(forKey: "debugRecognitionDelay")
        return seconds > 0 ? .milliseconds(Int(seconds * 1000)) : nil
    }

    /// `-debugAnalysisFEN "<FEN>"`: opens Analysis on that position (White at the bottom) as if it
    /// had been recognized: its castling rights count as assumed, as recognition leaves them. For
    /// screenshots of results the sample screenshot cannot produce, such as the assumed-castling
    /// caution.
    static var analysisFEN: String? {
        UserDefaults.standard.string(forKey: "debugAnalysisFEN")
    }

    /// `-debugReimportSampleAfter <seconds>`: that long after the first paywall appears,
    /// import the sample screenshot again the way the Find Best Move shortcut does, while the
    /// paywall is still up. For the UI test of a sheet replaced during its dismissal.
    static var reimportSampleAfter: Duration? {
        let seconds = UserDefaults.standard.double(forKey: "debugReimportSampleAfter")
        return seconds > 0 ? .milliseconds(Int(seconds * 1000)) : nil
    }

    /// `-uiTestProbe YES`: the Analysis screen carries an invisible element
    /// (`analysis.probe`) whose label holds the FEN, the best move in UCI and SAN, the run
    /// state and the import-to-result timeline, for UI tests that check results.
    static var uiTestProbe: Bool {
        UserDefaults.standard.bool(forKey: "uiTestProbe")
    }

    /// `-debugColorScheme light|dark`: forces the app's appearance, for screenshots in UI tests
    /// (setting `XCUIDevice.shared.appearance` does not reach the app on the iOS 26.5 simulator).
    static var colorScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "debugColorScheme") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// Applies `-resetStateForUITests`. Called by `ChessBestMoveApp` before the model is built.
    static func resetStateIfRequested() {
        guard resetState else { return }
        let vault = MonetizationKeychainVault()
        try? vault.removeData(for: .local)
        try? vault.removeData(for: .purchased)
        // The launch-cohort verdict survives reinstalling too (monetization.md section 11), so
        // a run that left it behind would not be a fresh install: a member verdict written by
        // an earlier run hides the credits indicator and the paywall from every test after it,
        // and those tests would pass without measuring anything.
        try? vault.removeData(for: .launchCohort)
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        MonetizationDebugOptions.demoDefaults.removePersistentDomain(forName: "com.motomatic.chessbestmove.monetization-demo")
    }
}
#endif
