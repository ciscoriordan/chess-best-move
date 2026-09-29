import Foundation
import Observation

// The Testing section of Settings (docs/monetization.md section 3, "Testing tools"): free
// analyses back to three, and the pack's 15 analyses without a purchase, in builds installed
// from a sandbox receipt only. Nothing here touches Pro: Pro comes from StoreKit, and a
// TestFlight or App Review purchase is already free in the sandbox.

// MARK: - Which channel installed this build

/// Which App Store channel installed this build.
///
/// Two signals answer it, and they answer the same question in the same three values:
///
/// - **StoreKit's `AppTransaction.environment`** (`MonetizationAppStoreEnvironment`), which Apple
///   signs: `.sandbox` for a copy TestFlight installed and for the copy App Review runs, `.xcode`
///   for a copy Xcode installed or a simulator run against a StoreKit configuration file, and
///   `.production` for a copy downloaded from the App Store. This is the documented signal and
///   the one that decides once it has been read, because it comes from Apple rather than from a
///   file name.
/// - **The name of the receipt file** the installer put in the app bundle
///   (`Bundle.main.appStoreReceiptURL`): `sandboxReceipt` for TestFlight, App Review and an Xcode
///   install, `receipt` for an App Store copy. It is synchronous and always available, so it is
///   what the first frame draws with, and it is the answer that stands if the app transaction
///   cannot be read at all.
///
/// Neither signal is written by the app. An App Store build has no way to be given a sandbox
/// receipt (it would have to have been installed by TestFlight, and then it is not an App Store
/// build) and no way to be given a sandbox app transaction. That is what makes this safe as the
/// gate for the Testing section, and the receipt name is the same signal Apple's own receipt
/// validation uses to choose between the production and the sandbox verification server.
///
/// **A simulator is not a sandbox build by its receipt.** Measured on Xcode 27 with the iOS 26.5
/// and iOS 27.0 runtimes, `Bundle.main.appStoreReceiptURL` on a simulator ends in
/// `StoreKit/receipt`, the App Store name, and the file usually does not exist. So a simulator
/// reads as `.appStore` and shows no Testing section; the UI tests that need the section put
/// another name in its place with the DEBUG-only launch argument below.
///
/// Both signals say which channel installed the build, never who is running it. The copy App
/// Review runs is installed the TestFlight way, so a reviewer sees the Testing section. That is
/// disclosed in the App Review notes (`metadata/en-US/review_notes.txt`).
enum MonetizationBuildChannel: Sendable, Hashable {
    /// An App Store copy: the receipt is named `receipt`, or the app transaction says
    /// `.production`. (A simulator reads this way too, by its receipt name.)
    case appStore
    /// TestFlight, App Review or an Xcode install: the receipt is named `sandboxReceipt`, or the
    /// app transaction says `.sandbox` or `.xcode`.
    case sandbox
    /// Neither signal said anything: no receipt at all, or one whose name is neither of the two,
    /// and no app transaction.
    case unknown

    /// The channel `receiptURL` names. A missing receipt is `.unknown`, never `.sandbox`: the
    /// Testing tools appear only where a signal positively says sandbox, so anything unusual
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

    /// The channel `environment` names, Apple's own answer.
    ///
    /// `.xcode` is a sandbox build: it is a copy Xcode installed, which buys from the StoreKit
    /// sandbox exactly as a TestFlight copy does. A value StoreKit adds after this build was
    /// compiled is `.unknown`, never `.sandbox`, for the same reason a missing receipt is.
    static func channel(environment: MonetizationAppStoreEnvironment) -> MonetizationBuildChannel {
        switch environment {
        case .production: .appStore
        case .sandbox, .xcode: .sandbox
        case .unrecognized: .unknown
        }
    }

    /// Whether this channel may show the Testing section in Settings. Only `.sandbox` may.
    var offersTestingTools: Bool { self == .sandbox }

    /// This build's channel from the receipt's name, read once: the receipt cannot change while
    /// the app runs. It is what `MonetizationBuildChannelResolver` starts from and falls back on.
    ///
    /// In DEBUG builds a launch argument can put another receipt name in its place, so both
    /// states can be seen on one simulator (see the override key below). That override is
    /// compiled out of Release, so the only thing that decides in a shipping build is the name
    /// of the receipt the installer wrote and the app transaction Apple signed.
    static let current: MonetizationBuildChannel = {
        #if DEBUG
        if let override = receiptNameOverride {
            return channel(receiptURL: override.isEmpty ? nil : URL(fileURLWithPath: "/StoreKit", isDirectory: true).appending(path: override))
        }
        #endif
        // `appStoreReceiptURL` is deprecated from iOS 18 in favor of StoreKit's
        // `AppTransaction.shared`, and this build carries that one warning deliberately
        // (App/APP_CONTRACT.md section 7 lists it). `AppTransaction.shared` is asynchronous, can
        // make a network round trip and can ask the user to sign in to their Apple Account,
        // while this value has to answer synchronously while Settings draws, offline and without
        // any prompt. That is why it is still read: it is the answer of the first frame and the
        // fallback, and `MonetizationBuildChannelResolver` replaces it with Apple's own as soon
        // as the app transaction has been read.
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

/// `AppTransaction.environment` as this app needs it, so the store logic and its tests do not
/// have to build a `StoreKit.AppStore.Environment`.
enum MonetizationAppStoreEnvironment: Sendable, Hashable {
    /// A copy downloaded from the App Store.
    case production
    /// A copy TestFlight installed, and the copy App Review runs.
    case sandbox
    /// A copy Xcode installed, and a simulator run against a StoreKit configuration file.
    case xcode
    /// A value StoreKit added after this build was compiled.
    case unrecognized
}

/// This build's channel, resolved once at launch (`MonetizationBuildChannel`).
///
/// **Why this exists (owner decision of 2026-09-28).** The Testing section used to be gated on
/// the receipt's file name alone, an API deprecated since iOS 18, and nobody had confirmed that
/// an App Review install on iPadOS 27 still writes a file named `sandboxReceipt`. If it does not,
/// the section a reviewer is sent to by the App Review notes was never on screen. The gate now
/// decides from `AppTransaction.environment`, which Apple documents and signs, and keeps the
/// receipt name as the fallback for the case where the app transaction cannot be read.
///
/// **And it still does not delay Settings drawing** (monetization.md section 3 defends that
/// property). `channel` starts at the receipt name's synchronous answer, so the first frame of
/// Settings is drawn from a value that is already there; the app transaction is read once, in a
/// task of its own at launch, and `channel` is `@Observable`, so a Settings that is already open
/// redraws if the answer changes. Nothing waits for it, and nothing is sequenced behind it: the
/// read is not inside the store's launch task, so the entitlements refresh and the products do
/// not wait for a call that can go to the network (`MonetizationStoreService.start`).
///
/// **It is read on every launch of every copy, including App Store copies**, because the whole
/// premise of this gate is that the receipt name may be wrong and the app cannot know which copy
/// it is until Apple answers. `AppTransaction.shared` can ask the user to sign in to their Apple
/// Account, so that prompt is possible at launch; it is accepted (owner decision of 2026-09-28,
/// recorded in APP_CONTRACT.md section 7), because it is Apple's documented API for the question,
/// the answer is cached by StoreKit after the first successful read, and a failed read costs
/// nothing but the receipt name's answer standing for another launch.
///
/// **An App Store copy still cannot show the section.** Apple answers `.production` for one, and
/// `.production` replaces a receipt name that said sandbox, so an App Store copy shows nothing
/// however it was installed. A `.sandbox` or `.xcode` answer does grant the section where the
/// receipt name said nothing or said App Store, which is what an App Review install on iPadOS 27
/// needed (`MonetizationTestingToolsTests.aReviewersBuildShowsTheTestingSection`).
@MainActor
@Observable
final class MonetizationBuildChannelResolver {
    /// The one the app uses. Views read `MonetizationBuildChannel.resolved`.
    static let shared = MonetizationBuildChannelResolver()

    /// The channel as currently known: the receipt name's answer until the app transaction has
    /// been read, Apple's answer afterwards.
    private(set) var channel: MonetizationBuildChannel

    /// Whether `channel` is Apple's own answer rather than the receipt name's.
    private(set) var isFromAppTransaction = false

    init(fallback: MonetizationBuildChannel = .current) {
        channel = fallback
    }

    /// Reads the app transaction's environment once and adopts its answer. A nil read (offline
    /// on a first launch, or a build with no app transaction at all) leaves the receipt name's
    /// answer in place, which is exactly the behavior this replaced.
    func resolve(readEnvironment: () async -> MonetizationAppStoreEnvironment?) async {
        guard !isFromAppTransaction else { return }
        let read = await readEnvironment()
        // An environment StoreKit adds after this build was compiled says nothing this build can
        // act on, so it counts as a read that said nothing rather than as an answer. Adopting it
        // would make `.unknown` the verdict and latch it, which would take the Testing section
        // away from a TestFlight or App Review build whose receipt name correctly said sandbox,
        // and the next launch would not ask again.
        guard let environment = read, environment != .unrecognized else {
            let reason = read == nil
                ? "the app transaction could not be read"
                : "the app transaction named an environment this build does not know"
            MonetizationLog.store.notice(
                "the build channel stays at the receipt name's answer: \(reason, privacy: .public)"
            )
            return
        }
        isFromAppTransaction = true
        let resolved = MonetizationBuildChannel.channel(environment: environment)
        if resolved != channel {
            MonetizationLog.store.notice(
                "the build channel changed from the receipt name's answer to Apple's: \(String(describing: resolved), privacy: .public)"
            )
        }
        channel = resolved
    }
}

extension MonetizationBuildChannel {
    /// This build's channel as the app should act on it now. Read it inside a view's body: it is
    /// an `@Observable` property, so the view redraws when the app transaction answers.
    @MainActor
    static var resolved: MonetizationBuildChannel { MonetizationBuildChannelResolver.shared.channel }
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
/// Both actions take the channel that asked for them and do nothing unless the caller's channel
/// **and** this build's own channel are `.sandbox` (`MonetizationCreditsService`). Those are the
/// second and third of three locks: the Settings section is not built at all outside a sandbox
/// build, a caller that reached these anyway has to name a sandbox channel, and even then the
/// build itself has to be one. The third lock is what makes one wrong call site harmless rather
/// than a shipping build that grants analyses.
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

    // The free launch window's two rows, "Launch cohort" and the "Show the purchase screens"
    // switch, were removed on 2026-09-28 with the window itself (monetization.md section 11).
    // With the window closed every install, a reviewer's included, already meets the three free
    // analyses and the purchase screen, so the switch had nothing left to do and the note under
    // it named a date the build no longer honors. `MonetizationLaunchCohortTesting` and
    // `MonetizationLaunchCohort.setLeavesCohortForTesting` are kept, so reopening the window
    // means restoring these rows and not rebuilding the mechanism.

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
