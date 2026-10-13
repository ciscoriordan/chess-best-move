import Foundation
import Observation

// The free launch window and the cohort it creates (docs/monetization.md section 11,
// build/ui-requests.md item 16). Everyone whose Apple Account first downloaded this app before
// `MonetizationRules.launchCohortCutoff` keeps unlimited analyses permanently and never sees a
// paywall, a price or a Pro row. Everyone who arrives afterwards meets the ordinary three free
// analyses and the paywall.
//
// The offer ended on 2026-10-13. Existing production customers keep their earned access.
// Sandbox installs use freemium without an override; synthetic download dates do not earn
// a production promotion. The old open-window policy remains available to regression tests.

enum MonetizationLaunchPolicy {
    case preservedAccess
    case openWindow
}

// MARK: - Where an Apple Account stands

/// The verdict for this Apple Account.
enum MonetizationLaunchCohortStatus: String, Sendable, Hashable, Codable {
    /// Apple's signed app transaction says this Apple Account first downloaded the app before
    /// the cutoff. Permanent: it is written to the Keychain and never taken back.
    case member
    /// Apple's signed app transaction says the first download was at or after the cutoff.
    case notMember
    /// No stored verdict or verified production transaction is available yet. New installs
    /// use the ordinary free allowance until access is recovered. Nothing is persisted.
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
    /// instead, which allows the app to ask Apple again without persisting a false denial.
    var carriesAVerdict: Bool { isMember || originalPurchaseDate != .distantFuture }

    /// The verdict this record gives under `cutoff`, which may be a later build's.
    ///
    /// Membership is sticky and the download date decides everything else, so this is the only
    /// place the two are combined. Ask `carriesAVerdict` first: this answers `.notMember` for a
    /// record that says nothing.
    ///
    /// A previously earned grant survives the end of the offer. The shipping policy ignores
    /// these records in sandbox without changing them, so production access is preserved.
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
/// **The offer has ended.** A stored production grant remains usable offline. Without one,
/// the app uses the ordinary three-analysis allowance while asking Apple for a verified
/// production download date. A pre-cutoff date recovers the grant after reinstalling or moving
/// devices. Sandbox dates never earn it. Failed reads persist nothing and can be retried.
/// `.openWindow` retains the old behavior solely for historical regression tests.
@MainActor
@Observable
final class MonetizationLaunchCohort {
    /// What has been decided. `.undecided` until a stored verdict or Apple's app transaction
    /// says otherwise.
    private(set) var status: MonetizationLaunchCohortStatus

    /// Historical sandbox override, retained for regression fixtures and older defaults.
    /// The shipping Settings screen no longer exposes it.
    private(set) var leavesCohortForTesting: Bool

    @ObservationIgnored private let vault: any MonetizationVault
    @ObservationIgnored private let channel: MonetizationBuildChannel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cutoff: Date
    @ObservationIgnored private let policy: MonetizationLaunchPolicy
    @ObservationIgnored private var hasResolvedPreservedAccess = false
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
        cutoff: Date = MonetizationRules.launchCohortCutoff,
        policy: MonetizationLaunchPolicy = .preservedAccess
    ) {
        self.vault = vault
        self.channel = channel
        self.defaults = defaults
        self.cutoff = cutoff
        self.policy = policy
        if policy == .preservedAccess && channel == .sandbox {
            // Keep stored records intact for the customer's production app. TestFlight and
            // App Review exercise purchases rather than receiving a real launch promotion.
            status = .notMember
        } else if MonetizationRules.launchWindowIsOpen(cutoff: cutoff) {
            // Synchronous, so the first frame is already right for everybody who has been decided.
            status = Self.storedStatus(vault: vault, cutoff: cutoff)
        } else {
            // The window is closed, so there is no cohort to be in: not for a fresh install, and
            // not for an Apple Account whose Keychain still holds a member verdict a build with
            // an open window wrote (membership is sticky, see `status(under:)`). Nothing is read
            // and nothing is written, so the stored record is left exactly as it is and a build
            // that reopens the window finds it again. `resolve` then has nothing to ask Apple
            // for either, which takes the app transaction off the launch path.
            status = .notMember
        }
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
    /// Shipping builds require a member verdict. The historical open-window policy also
    /// grants temporary access while undecided; sandbox testing overrides can suppress it.
    var grantsUnlimitedAnalyses: Bool {
        guard !leavesCohortForTesting else { return false }
        switch status {
        case .member: return true
        case .undecided: return policy == .openWindow
        case .notMember: return false
        }
    }

    /// Whether a confirmed grant is currently honored.
    var offerIsConfirmed: Bool { grantsUnlimitedAnalyses && status == .member }

    /// Whether a stored record or verified transaction has supplied a verdict.
    var isDecided: Bool { status != .undecided }

    /// Reads Apple's app transaction and writes the verdict, unless one is already stored.
    ///
    /// `readOriginalPurchaseDate` is `MonetizationStoreKitClient.appTransactionOriginalPurchaseDate`,
    /// which returns nil when the transaction could not be read or did not verify. Nothing is
    /// written for a nil: the verdict is made only from an answer that actually arrived.
    ///
    /// The preserved-access policy checks the signed environment before using download dates.
    /// Product loading runs independently, so a slow transaction read cannot hide purchases.
    func resolve(
        readEnvironment: () async -> MonetizationAppStoreEnvironment? = { nil },
        readOriginalPurchaseDate: () async -> Date?
    ) async {
        guard !isFixedForDebug, !isResolving else { return }
        if policy == .preservedAccess {
            guard !hasResolvedPreservedAccess else { return }
        } else {
            guard status == .undecided else { return }
        }
        isResolving = true
        defer { isResolving = false }
        if policy == .preservedAccess {
            // The signed environment is authoritative even if the deprecated receipt filename
            // gave the wrong initial channel. Never infer promotion eligibility from a sandbox
            // transaction's synthetic date, or overwrite an earned production record with it.
            guard let environment = await readEnvironment(), environment != .unrecognized else { return }
            guard environment == .production else {
                status = .notMember
                hasResolvedPreservedAccess = true
                return
            }
            let stored = Self.storedStatus(vault: vault, cutoff: cutoff)
            if stored != .undecided {
                status = stored
                hasResolvedPreservedAccess = true
                return
            }
        }
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
        hasResolvedPreservedAccess = policy == .preservedAccess
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
/// The plan row must never read "Pro, lifetime" for someone who bought nothing, so the state has
/// a name of its own.
///
/// The plan describes current access without assuming an unverified first-download date.
enum MonetizationLaunchCohortCopy {
    /// The value of Settings' Plan row while the offer is being granted.
    static let planRow = "Unlimited"

    /// The line the plan screen shows under that value. It claims nothing about when this Apple
    /// Account installed the app, and it says what Restore purchases is still for, because a
    /// member who bought nothing is told "No previous purchases found".
    static let planDetail =
        "Every analysis is unlimited, at no cost. Restore purchases is here for anything you bought on another device."
}
