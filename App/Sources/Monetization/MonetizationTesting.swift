import Foundation
import Observation

// The Testing section of Settings (docs/monetization.md section 3, "Testing tools"): free
// analyses back to three, and the pack's 15 analyses without a purchase, in builds installed
// from a sandbox receipt only. Nothing here touches Pro: Pro comes from StoreKit, and a
// TestFlight or App Review purchase is already free in the sandbox.

// MARK: - Which channel installed this build

/// Which App Store channel installed this build, read from the name of the receipt file the
/// installer put in the app bundle (`Bundle.main.appStoreReceiptURL`).
///
/// Apple gives that file one of two names and no other:
///
/// - `sandboxReceipt` on a device whose copy was installed by TestFlight, on the copy App
///   Review runs, and on a copy installed by Xcode. All of those buy from the StoreKit sandbox.
/// - `receipt` for a copy downloaded from the App Store.
///
/// The name is written by whoever installed the app, not by the app. An App Store build has no
/// way to be given a sandbox receipt: it would have to be installed by TestFlight instead, and
/// then it is not an App Store build. That is what makes this safe as the gate for the Testing
/// section, and it is the same signal Apple's own receipt validation uses to choose between the
/// production and the sandbox verification server.
///
/// **A simulator is not a sandbox build here.** Measured on Xcode 27 with the iOS 26.5 runtime,
/// `Bundle.main.appStoreReceiptURL` on a simulator ends in `StoreKit/receipt`, the App Store
/// name, and the file usually does not exist. So a simulator reads as `.appStore` and shows no
/// Testing section; the UI tests that need the section put another name in its place with the
/// DEBUG-only launch argument below.
///
/// The name says which channel installed the build, never who is running it. The copy App
/// Review runs is installed the TestFlight way and carries a sandbox receipt, so a reviewer
/// sees the Testing section. That is disclosed in the App Review notes
/// (`metadata/en-US/review_notes.txt`).
enum MonetizationBuildChannel: Sendable, Hashable {
    /// The receipt is named `receipt`: an App Store copy (and, measured, a simulator).
    case appStore
    /// The receipt is named `sandboxReceipt`: TestFlight, App Review or an Xcode install.
    case sandbox
    /// There is no receipt at all, or it carries a name that is neither of the two.
    case unknown

    /// The channel `receiptURL` names. A missing receipt is `.unknown`, never `.sandbox`: the
    /// Testing tools appear only where the receipt positively says sandbox, so anything unusual
    /// keeps the shipping behavior.
    ///
    /// Only the file name decides. A directory in the path called `sandboxReceipt` would not
    /// make an App Store receipt a sandbox one.
    static func channel(receiptURL: URL?) -> MonetizationBuildChannel {
        switch receiptURL?.lastPathComponent {
        case "sandboxReceipt": .sandbox
        case "receipt": .appStore
        default: .unknown
        }
    }

    /// Whether this channel may show the Testing section in Settings. Only `.sandbox` may.
    var offersTestingTools: Bool { self == .sandbox }

    /// This build's channel, read once: the receipt cannot change while the app runs.
    ///
    /// In DEBUG builds a launch argument can put another receipt name in its place, so both
    /// states can be seen on one simulator (see the override key below). That override is
    /// compiled out of Release, so the only thing that decides in a shipping build is the name
    /// of the receipt the installer wrote.
    static let current: MonetizationBuildChannel = {
        #if DEBUG
        if let override = receiptNameOverride {
            return channel(receiptURL: override.isEmpty ? nil : URL(fileURLWithPath: "/StoreKit", isDirectory: true).appending(path: override))
        }
        #endif
        // `appStoreReceiptURL` is deprecated from iOS 18 in favor of StoreKit's
        // `AppTransaction.shared`, and this build carries that one warning deliberately
        // (App/APP_CONTRACT.md section 7 lists it). `AppTransaction.shared` is asynchronous,
        // can make a network round trip and can ask the user to sign in to their Apple
        // Account; this gate has to answer synchronously while Settings draws, offline, and
        // without any prompt. The receipt's name is a local file name the installer wrote, so
        // it always answers and it cannot be wrong.
        //
        // The warning cannot be silenced without hiding the dependency. Swift suppresses a
        // deprecation only inside a declaration that is itself deprecated, so moving the call
        // behind a wrapper moves the warning to the wrapper's call site rather than removing
        // it, and the alternatives (a runtime selector lookup, or deciding the channel by which
        // receipt file exists) either hide which API is used or change the answer: an Xcode
        // install on a device is named `sandboxReceipt` before any receipt file is written.
        return channel(receiptURL: Bundle.main.appStoreReceiptURL)
    }()

    #if DEBUG
    /// `-monetizationReceiptName sandboxReceipt|receipt|none`: pretend the receipt carries that
    /// name, for the UI tests of the Testing section. `none` pretends there is no receipt.
    static let receiptNameOverrideKey = "monetizationReceiptName"

    /// The overridden receipt name, an empty string for "no receipt at all", or nil when the
    /// launch argument was not passed.
    private static var receiptNameOverride: String? {
        guard let name = UserDefaults.standard.string(forKey: receiptNameOverrideKey) else { return nil }
        return name == "none" ? "" : name
    }
    #endif
}

// MARK: - What a grant is

/// The analyses the Testing section grants, and the pack transaction ids it credits them as.
///
/// A grant goes through the ordinary pack ledger (`MonetizationPackLedger.creditPack`), so it
/// is worth exactly what a bought pack is worth and is spent, merged and stored by the same
/// code. Its transaction id is one the App Store cannot produce, which is what lets "Reset free
/// analyses" take back everything this section gave and nothing that was bought.
enum MonetizationTestingGrant {
    /// One press of "Add 15 analyses" is worth one pack.
    static var analysesPerGrant: Int { ProductID.creditsPerPack }

    /// The first id used for a granted pack. App Store transaction ids are decimal numbers of
    /// about 15 digits (they are carried as JSON numbers, so they stay below 2^53); an id with
    /// the top bit set is 9.2 x 10^18 and can never be one of Apple's.
    static let firstTransactionID: UInt64 = 1 << 63

    /// Whether `id` is one this section granted rather than one the App Store issued.
    static func isTestingTransactionID(_ id: UInt64) -> Bool { id >= firstTransactionID }

    /// The next id to grant: the first testing id `used` does not already hold. Ids of packs
    /// that were granted and then taken back stay in the record as revoked, and crediting a
    /// revoked id does nothing, so they have to be skipped.
    static func nextTransactionID(notIn used: Set<UInt64>) -> UInt64 {
        var id = firstTransactionID
        while used.contains(id) { id += 1 }
        return id
    }
}

/// The counts the Testing section shows, so a tester can see what an action did.
struct MonetizationTestingCounts: Sendable, Hashable {
    let freeRemaining: Int
    let freeAllowance: Int
    let purchasedRemaining: Int
    /// Boards a credit was already spent on. They are what makes a re-analysis free under the
    /// 3-square rule (monetization.md section 5), so a reset forgets them.
    let paidBoards: Int
    /// False while the stored record cannot be read (a locked Keychain): the counts are then
    /// not the real ones and neither action can change anything.
    let isStorageReadable: Bool
}

/// The two Testing actions, on the credits service. `MonetizationCreditsService` implements
/// them; the Settings section reaches them by casting `AppModel.credits`, so the shell's
/// `CreditsService` contract does not have to carry them.
///
/// Both actions take the channel that asked for them and do nothing unless it is `.sandbox`.
/// That is the second of two locks: the Settings section is not built at all outside a sandbox
/// build, and even a caller that reached these would change nothing in an App Store build.
@MainActor
protocol MonetizationTestingGrants: AnyObject, Observable, Sendable {
    var testingCounts: MonetizationTestingCounts { get }

    /// Free analyses back to the full allowance, the paid boards forgotten (so no board is free
    /// by the 3-square rule any more) and every granted pack taken back. Bought packs, Pro and
    /// the analyses spent from bought packs are untouched. Returns whether anything changed.
    @discardableResult
    func resetFreeAnalyses(for channel: MonetizationBuildChannel) -> Bool

    /// The 15 analyses a pack grants, credited without a purchase. Returns whether anything
    /// changed.
    @discardableResult
    func grantTestingAnalyses(for channel: MonetizationBuildChannel) -> Bool
}

// MARK: - Copy

/// The text of the Testing section (design.md 14: sentence case, plain verbs, American
/// spelling). It is not purchase-screen copy, so it may say "free".
enum MonetizationTestingCopy {
    static let sectionLabel = "Testing"
    static let note =
        "These controls are in TestFlight builds and never in an App Store build. They grant analyses, never Pro: Pro comes from a purchase, which costs nothing in the TestFlight sandbox."

    static let freeRow = "Free analyses"
    static let purchasedRow = "Purchased analyses"
    static let paidBoardsRow = "Boards already paid for"

    static let reset = "Reset free analyses"
    static let resetQuestion = "Reset free analyses?"
    static let resetDetail =
        "Free analyses go back to 3, the boards already paid for are forgotten, and analyses added here are taken back. Bought analyses and Pro are not touched."
    static let resetConfirm = "Reset"

    static func grant(_ count: Int) -> String { "Add \(count) analyses" }
    static func grantQuestion(_ count: Int) -> String { "Add \(count) analyses?" }
    static func grantDetail(_ count: Int) -> String {
        "Adds the same \(count) analyses the pack grants, without a purchase. \"\(reset)\" takes them back."
    }
    static let grantConfirm = "Add"

    static let cancel = "Cancel"

    // MARK: The free launch window

    /// The row that says where this Apple Account stands with the free launch window.
    static let launchCohortRow = "Launch cohort"
    static func launchCohortValue(_ status: MonetizationLaunchCohortStatus) -> String {
        switch status {
        case .member: "Member"
        case .notMember: "Not a member"
        case .undecided: "Not decided yet"
        }
    }

    /// The switch that makes the build behave as an install made after the window closed. Its
    /// name says what a tester or a reviewer wants from it, and the note says what it does.
    static let showsPurchaseScreens = "Show the purchase screens"

    /// The second paragraph of the section's footer. App Review installs the app during the
    /// free window, so a reviewer is in the launch cohort and would otherwise never reach the
    /// paywall or the four products (monetization.md section 11).
    static let launchCohortNote =
        "Chess Best Move is unlimited for everyone whose Apple Account installed it before \(MonetizationLaunchCohortCopy.cutoffDate), and this build is one of those installs, so it shows no purchase screen. Turn on \"\(showsPurchaseScreens)\" and it behaves as an install made after that date: three analyses, then the purchase screen with all four products. Turn it off to go back."

    /// "2 of 3" for the free row.
    static func freeValue(_ counts: MonetizationTestingCounts) -> String {
        "\(counts.freeRemaining) of \(counts.freeAllowance)"
    }

    /// The plural of "analysis" this count needs.
    static func analyses(_ count: Int) -> String {
        count == 1 ? "1 analysis" : "\(count) analyses"
    }

    /// The plural of "board" this count needs.
    static func boards(_ count: Int) -> String {
        count == 1 ? "1 board" : "\(count) boards"
    }

    /// What the reset did: the free analyses it restored, the boards it forgot and the granted
    /// analyses it took back.
    static func resetDone(before: MonetizationTestingCounts, after: MonetizationTestingCounts) -> String {
        var sentences = ["Free analyses back to \(after.freeRemaining) of \(after.freeAllowance)."]
        if before.paidBoards > 0 {
            sentences.append("\(boards(before.paidBoards)) forgotten.")
        }
        let takenBack = max(0, before.purchasedRemaining - after.purchasedRemaining)
        if takenBack > 0 {
            sentences.append("\(analyses(takenBack)) added here taken back.")
        }
        return sentences.joined(separator: " ")
    }

    /// What the grant did.
    static func grantDone(before: MonetizationTestingCounts, after: MonetizationTestingCounts) -> String {
        let added = max(0, after.purchasedRemaining - before.purchasedRemaining)
        return "\(analyses(added)) added. \(after.purchasedRemaining) purchased now."
    }

    /// Neither action could change anything: the stored record could not be read (a Keychain
    /// that is not available yet), so nothing was written over it.
    static let nothingChanged = "Nothing changed: the stored analyses could not be read."
}
