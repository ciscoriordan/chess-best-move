import Foundation
import Observation

// The free launch window and the cohort it creates (docs/monetization.md section 11,
// build/ui-requests.md item 16). Everyone whose Apple Account first downloaded this app before
// `MonetizationRules.launchCohortCutoff` keeps unlimited analyses permanently and never sees a
// paywall, a price or a Pro row. Everyone who arrives afterwards meets the ordinary three free
// analyses and the paywall.

// MARK: - Where an Apple Account stands

/// The verdict for this Apple Account.
enum MonetizationLaunchCohortStatus: String, Sendable, Hashable, Codable {
    /// Apple's signed app transaction says this Apple Account first downloaded the app before
    /// the cutoff. Permanent: it is written to the Keychain and never taken back.
    case member
    /// Apple's signed app transaction says the first download was at or after the cutoff.
    case notMember
    /// Nothing has been decided: no verdict is stored, and the app transaction has not been
    /// read yet or could not be read (a first launch with no connection). The app grants
    /// unlimited analyses while this lasts and writes nothing down; see
    /// `grantsUnlimitedAnalyses`.
    case undecided
}

/// The stored verdict.
///
/// It keeps the date the verdict was made from as well as the verdict, so a build that moves
/// the cutoff can decide again from Apple's own answer instead of re-reading it. The decision
/// only ever moves one way: a stored member stays a member even if a later build moves the
/// cutoff earlier, and a stored non-member becomes a member when a later build moves the
/// cutoff past their download date (item 16: if review slips, the date moves in a new build).
struct MonetizationLaunchCohortRecord: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version = MonetizationLaunchCohortRecord.currentVersion
    /// The verdict as the build that wrote it decided.
    var isMember: Bool
    /// `AppTransaction.originalPurchaseDate`: when this Apple Account first downloaded this
    /// app, signed by Apple.
    var originalPurchaseDate: Date
    /// The cutoff that date was compared against.
    var cutoff: Date

    init(isMember: Bool, originalPurchaseDate: Date, cutoff: Date) {
        self.isMember = isMember
        self.originalPurchaseDate = originalPurchaseDate
        self.cutoff = cutoff
    }

    private enum CodingKeys: String, CodingKey {
        case version, isMember, originalPurchaseDate, cutoff
    }

    /// Decodes field by field, like the credit records, so a record written by another app
    /// version never fails to decode as a whole. A field that is missing falls back on its own;
    /// whether what is left still says anything is `carriesAVerdict`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        isMember = (try? container.decodeIfPresent(Bool.self, forKey: .isMember)) ?? false
        originalPurchaseDate = (try? container.decodeIfPresent(Date.self, forKey: .originalPurchaseDate)) ?? .distantFuture
        cutoff = (try? container.decodeIfPresent(Date.self, forKey: .cutoff)) ?? .distantPast
    }

    /// Whether this record carries an answer at all.
    ///
    /// Both fields fall back on their own, so a record whose verdict **and** download date both
    /// went missing decodes as a non-member without anybody having decided that. Reading it as
    /// one would be the single unrecoverable mistake of this feature: a member who was promised
    /// the app free forever would be paywalled, and `resolve` would never ask Apple again,
    /// because there is a verdict in front of it. Treated as no record, the cohort is undecided
    /// instead, which grants the offer for that launch only and asks Apple at once.
    var carriesAVerdict: Bool { isMember || originalPurchaseDate != .distantFuture }

    /// The verdict this record gives under `cutoff`, which may be a later build's.
    ///
    /// Membership is sticky and the download date decides everything else, so this is the only
    /// place the two are combined. Ask `carriesAVerdict` first: this answers `.notMember` for a
    /// record that says nothing.
    func status(under cutoff: Date) -> MonetizationLaunchCohortStatus {
        isMember || originalPurchaseDate < cutoff ? .member : .notMember
    }
}

// MARK: - Deciding it

/// Decides, once and durably, whether this Apple Account is in the free launch cohort, and
/// remembers the answer in the Keychain.
///
/// **Why `AppTransaction.originalPurchaseDate` and not a first-launch flag.** Apple signs the
/// app transaction, it says when this Apple Account first downloaded THIS app, and it survives
/// deleting the app and moving to a new device. A local "first launch was before X" flag
/// survives neither, and moves when the user moves the device clock. Nothing here reads the
/// device clock: the comparison is between Apple's signed date and a constant compiled into
/// the build, so changing the clock changes nothing.
///
/// **What it costs.** `AppTransaction.shared` is asynchronous, can make a network round trip
/// and can fail offline. That is why the Testing gate in `MonetizationTesting.swift` reads the
/// receipt's file name instead: that gate has to answer synchronously while Settings draws.
/// This one may take its time, because the stored verdict answers every launch after the first
/// and the app has an honest answer for the launch where there is none yet.
///
/// **An undecided cohort grants unlimited analyses.** On a first launch with no connection
/// there is no stored verdict and no app transaction, so nothing is known. The app then behaves
/// as if this were a member and writes nothing down, for the length of that launch:
///
/// - Treating an unknown user as a non-member would put a paywall in front of someone who was
///   promised the app free forever, with no way for them to say so. That is unrecoverable.
/// - Treating an unknown user as a member costs, at most, unlimited analyses until the device
///   next reaches the network. It corrects itself the moment an answer arrives, and it takes
///   nothing away in the meantime: an analysis allowed this way is allowed as Pro is allowed,
///   so it spends none of the three free analyses.
///
/// It is never written down, so one failed read cannot make somebody a member forever: the
/// question is asked again at every launch and every return to the foreground until Apple
/// answers it.
@MainActor
@Observable
final class MonetizationLaunchCohort {
    /// What has been decided. `.undecided` until a stored verdict or Apple's app transaction
    /// says otherwise.
    private(set) var status: MonetizationLaunchCohortStatus

    /// True while the Testing section has asked this build to behave as an install made after
    /// the window closed (`MonetizationLaunchCohortTesting`). Always false outside a sandbox
    /// build.
    private(set) var leavesCohortForTesting: Bool

    @ObservationIgnored private let vault: any MonetizationVault
    @ObservationIgnored private let channel: MonetizationBuildChannel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cutoff: Date
    @ObservationIgnored private var isResolving = false
    /// A DEBUG launch argument fixed the status; Apple's answer must not replace it.
    @ObservationIgnored private var isFixedForDebug = false

    private enum DefaultsKey {
        static let leavesCohortForTesting = "monetization.launchCohort.leftForTesting"
    }

    init(
        vault: any MonetizationVault,
        channel: MonetizationBuildChannel = .current,
        defaults: UserDefaults = .standard,
        cutoff: Date = MonetizationRules.launchCohortCutoff
    ) {
        self.vault = vault
        self.channel = channel
        self.defaults = defaults
        self.cutoff = cutoff
        // Synchronous, so the first frame is already right for everybody who has been decided.
        status = Self.storedStatus(vault: vault, cutoff: cutoff)
        // The override only exists where the Testing section exists, and it is read through the
        // same channel gate, so a value left in another build's defaults can do nothing.
        leavesCohortForTesting = channel.offersTestingTools && defaults.bool(forKey: DefaultsKey.leavesCohortForTesting)
        #if DEBUG
        if let forced = Self.debugStatus {
            status = forced
            isFixedForDebug = true
        }
        #endif
    }

    /// Whether the app grants unlimited analyses and hides every commercial surface.
    ///
    /// True for a member and while nothing is decided (see the note above); false once Apple
    /// has said this Apple Account arrived after the window, and false while the Testing
    /// section asks this build to behave as a post-window install.
    var grantsUnlimitedAnalyses: Bool {
        guard !leavesCohortForTesting else { return false }
        switch status {
        case .member, .undecided: return true
        case .notMember: return false
        }
    }

    /// Whether Apple has actually said this Apple Account is a member, **and** the offer is
    /// being granted.
    ///
    /// The grant above is deliberately wider than the truth: an undecided cohort is granted
    /// unlimited analyses, because denying them would be the unrecoverable mistake. Copy that
    /// makes a claim about the past reads this narrower one instead. Settings otherwise tells
    /// a first launch with no connection "you installed Chess Best Move before October 15,
    /// 2026, so every analysis is unlimited and stays that way" - a dated, permanent promise
    /// to somebody who may turn out to have installed it in November, and the next launch
    /// would take it back.
    var offerIsConfirmed: Bool { grantsUnlimitedAnalyses && status == .member }

    /// Whether Apple has answered. The app behaves the same for `.undecided` as for `.member`,
    /// so this is only for the Testing section and the logs.
    var isDecided: Bool { status != .undecided }

    /// Reads Apple's app transaction and writes the verdict, unless one is already stored.
    ///
    /// `readOriginalPurchaseDate` is `MonetizationStoreKitClient.appTransactionOriginalPurchaseDate`,
    /// which returns nil when the transaction could not be read or did not verify. Nothing is
    /// written for a nil: the verdict is made only from an answer that actually arrived.
    func resolve(readOriginalPurchaseDate: () async -> Date?) async {
        guard !isFixedForDebug, status == .undecided, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        guard let originalPurchaseDate = await readOriginalPurchaseDate() else {
            MonetizationLog.store.notice("launch cohort still undecided: the app transaction could not be read")
            return
        }
        let record = MonetizationLaunchCohortRecord(
            isMember: originalPurchaseDate < cutoff,
            originalPurchaseDate: originalPurchaseDate,
            cutoff: cutoff
        )
        // The verdict holds for this launch whether or not it could be stored; a Keychain that
        // is not available yet only means the next launch asks Apple again.
        save(record)
        status = record.status(under: cutoff)
        MonetizationLog.store.notice(
            "launch cohort decided: \(self.status.rawValue, privacy: .public)"
        )
    }

    // MARK: Testing section

    /// Makes this build behave as an install made after the window closed, so App Review can
    /// reach the paywall and every product (`SettingsTesting.swift`). Refused unless the caller
    /// and this build both carry a sandbox receipt, which is the same pair of locks the other
    /// Testing actions use. Returns whether anything changed.
    @discardableResult
    func setLeavesCohortForTesting(_ leaves: Bool, for channel: MonetizationBuildChannel) -> Bool {
        guard channel.offersTestingTools, self.channel.offersTestingTools else { return false }
        guard leaves != leavesCohortForTesting else { return false }
        defaults.set(leaves, forKey: DefaultsKey.leavesCohortForTesting)
        leavesCohortForTesting = leaves
        MonetizationLog.store.notice("testing: leaves the launch cohort = \(leaves, privacy: .public)")
        return true
    }

    // MARK: Storage

    /// The verdict in the Keychain, or `.undecided` when there is none, it cannot be read, or
    /// it cannot be decoded. Nothing is written over a record that could not be read.
    private static func storedStatus(vault: any MonetizationVault, cutoff: Date) -> MonetizationLaunchCohortStatus {
        let data: Data?
        do {
            data = try vault.data(for: .launchCohort)
        } catch {
            MonetizationLog.store.error("reading the launch-cohort verdict failed: \(String(describing: error), privacy: .public)")
            return .undecided
        }
        guard let data else { return .undecided }
        guard let record = try? JSONDecoder().decode(MonetizationLaunchCohortRecord.self, from: data) else {
            MonetizationLog.store.error("the launch-cohort verdict could not be decoded and was left untouched")
            return .undecided
        }
        guard record.carriesAVerdict else {
            MonetizationLog.store.error("the stored launch-cohort record carries no verdict and was left untouched")
            return .undecided
        }
        return record.status(under: cutoff)
    }

    private func save(_ record: MonetizationLaunchCohortRecord) {
        do {
            try vault.setData(try JSONEncoder().encode(record), for: .launchCohort)
        } catch {
            MonetizationLog.store.error("saving the launch-cohort verdict failed: \(String(describing: error), privacy: .public)")
        }
    }

    #if DEBUG
    /// `-monetizationLaunchCohort member|notMember|undecided`: fixes the status, for the UI
    /// tests and the screenshot runs, which must not depend on what a simulator's StoreKit
    /// configuration puts in the app transaction. Compiled out of Release.
    static let debugStatusKey = "monetizationLaunchCohort"

    private static var debugStatus: MonetizationLaunchCohortStatus? {
        guard let name = UserDefaults.standard.string(forKey: debugStatusKey) else { return nil }
        return MonetizationLaunchCohortStatus(rawValue: name)
    }
    #endif
}

/// The Testing section's handle on the launch cohort. `MonetizationStoreService` implements it;
/// the section reaches it by casting `AppModel.store`, so the `StoreService` contract does not
/// have to carry a testing-only control.
@MainActor
protocol MonetizationLaunchCohortTesting: AnyObject, Observable, Sendable {
    /// What has been decided for this Apple Account, whatever the testing override says.
    var launchCohortStatus: MonetizationLaunchCohortStatus { get }
    /// Whether the build is currently behaving as an install made after the window closed.
    var leavesLaunchCohortForTesting: Bool { get }
    /// Turns that on or off. Does nothing unless `channel` is the sandbox one.
    @discardableResult
    func setLeavesLaunchCohortForTesting(_ leaves: Bool, for channel: MonetizationBuildChannel) -> Bool
}

// MARK: - Copy

/// What Settings says to a member. It is not purchase-screen copy: there is nothing to buy on
/// this screen for the people who read it.
///
/// The plan row must never read "Pro, lifetime" for someone who bought nothing, so the state
/// has its own name: the **launch offer**.
enum MonetizationLaunchCohortCopy {
    /// The cutoff as a reader sees it, in the app and in the App Store listing.
    static let cutoffDate = "October 15, 2026"

    /// The value of Settings' Plan row for a member Apple has confirmed.
    static let planRow = "Unlimited, launch offer"

    /// The value of the Plan row while the offer is being granted but nothing has been decided
    /// yet (a first launch with no connection). It says what the app is doing and claims
    /// nothing about when this Apple Account installed it, because that is not known.
    static let undecidedPlanRow = "Unlimited"

    /// The footer under Settings' Purchases card for a member. It says why they have it, that
    /// it lasts, and what the Restore purchases row above it is still for.
    static let planFooter =
        "You installed Chess Best Move before \(cutoffDate), so every analysis is unlimited and stays that way, at no cost. Restore purchases is here for anything you bought on another device."
}
