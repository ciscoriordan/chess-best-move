// Monetization: StoreKit 2 purchases, free and purchased analysis credits, the paywall and
// the pack downsell (docs/monetization.md sections 2-6, docs/design.md 9.7).
//
// Entry points (App/APP_CONTRACT.md section 3):
//   MonetizationFeature.makeStoreService() -> any StoreService
//   MonetizationFeature.makeCreditsService(store:) -> any CreditsService
//   PaywallView(context:onFinish:), DownsellView(context:onFinish:)
// Views other features may place:
//   LastFreeAnalysisNotice(session:)   the line under the result that used the last free analysis
//   SwitchToYearlyCard()               the one-time card for weekly subscribers (monetization.md 4.9)
// Shared configuration:
//   MonetizationLegalLinks.termsOfUse / .privacyPolicy

import Foundation

enum MonetizationFeature {
    /// The live store: StoreKit 2 through `MonetizationLiveStoreKitClient`, with the launch
    /// cohort decided from Apple's app transaction and kept in the Keychain
    /// (`MonetizationLaunchCohort`).
    @MainActor
    static func makeStoreService() -> any StoreService {
        #if DEBUG
        if MonetizationDebugOptions.demoFreeRemaining != nil {
            let defaults = MonetizationDebugOptions.demoDefaults
            // The scripted StoreKit starts empty at every launch; a Pro state cached by an earlier
            // launch would contradict it.
            MonetizationStoreService.forgetCachedEntitlements(in: defaults)
            // The demo is the freemium app, so its scripted app transaction is a post-window
            // install (`MonetizationScriptedStoreKitClient.appTransactionPurchaseDate`) and its
            // cohort lives in memory. `-monetizationLaunchCohort member` overrides it.
            return MonetizationStoreService(
                client: MonetizationDebugOptions.makeDemoClient(),
                launchCohort: MonetizationDebugOptions.makeDemoLaunchCohort(defaults: defaults),
                defaults: defaults
            )
        }
        #endif
        return MonetizationStoreService(
            client: MonetizationLiveStoreKitClient(),
            launchCohort: MonetizationLaunchCohort(vault: MonetizationKeychainVault())
        )
    }

    /// The live credits service: Keychain storage, with purchased credits derived from the
    /// Keychain record and the transaction history (monetization.md section 3).
    @MainActor
    static func makeCreditsService(store: any StoreService) -> any CreditsService {
        #if DEBUG
        if let freeRemaining = MonetizationDebugOptions.demoFreeRemaining {
            return MonetizationCreditsService(
                store: store,
                vault: MonetizationDebugOptions.makeDemoVault(freeRemaining: freeRemaining)
            )
        }
        #endif
        return MonetizationCreditsService(
            store: store,
            vault: MonetizationKeychainVault()
        )
    }
}

/// Legal links shown on the paywall (and available to Settings). One place, so the URLs can
/// be changed without touching any view.
enum MonetizationLegalLinks {
    /// The published Terms of Use (the app's End User License Agreement).
    ///
    /// Not Apple's standard EULA: that agreement forbids redistribution and other things
    /// GPLv3 grants, and GPLv3 section 10 does not allow the app to impose such restrictions.
    /// Stockfish is linked into the binary, so the whole app is under GPLv3
    /// (Packages/ChessEngine/README.md, "License obligations"). The published terms grant
    /// GPLv3 for the software and add no restriction to it.
    static let termsOfUse = URL(string: "https://ciscoriordan.github.io/chessbestmove.app/terms.html")!

    /// The published privacy policy.
    static let privacyPolicy = URL(string: "https://ciscoriordan.github.io/chessbestmove.app/privacy.html")!
}

/// Apple's own pages the app sends a reader to.
enum MonetizationAppleLinks {
    /// The Apple Account's subscriptions, which the App Store app opens.
    ///
    /// It is the fallback for "Manage subscription" when `AppStore.showManageSubscriptions(in:)`
    /// refuses to show its sheet, so that tap always does something
    /// (`MonetizationManageSubscriptionFeedback`). Apple documents this address as the way to
    /// reach subscriptions from outside the app, and it resolves in the App Store app and in a
    /// browser, so it is not a link that can go dead the way an app's own page could.
    static let accountSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}

/// Numbers from monetization.md sections 3 and 5.
enum MonetizationRules {
    /// Free analyses per Apple Account on a device. Never refilled.
    static let freeAllowance = 3
    /// A board that differs from a paid board by at most this many squares is free, and then only
    /// when every differing square is one that paid board allows to change (`MonetizationFreeEdit`)
    /// and legal play from it does not explain the change (`MonetizationPlayRule`). Taking exactly
    /// one piece off, and moving one piece to a square that was empty, are fixes whether or not
    /// play explains them (`MonetizationCreditPolicy`).
    static let maximumFreeSquareDifference = 3
    /// How many paid boards are remembered.
    static let rememberedPaidBoards = 20
    /// The downsell is not shown again for this long after it was closed without buying.
    static let downsellCooldown: TimeInterval = 24 * 60 * 60
    /// The "Switch to yearly" card appears from this paid week on.
    static let switchToYearlyFromPaidWeek = 4
    /// Apple's longest billing grace period (App Store Connect offers 3, 16 or 28 days). A
    /// subscription StoreKit still lists after its expiration date is kept as Pro for the next
    /// launch until this long after that date, while the exact end of its grace period is not
    /// known yet.
    static let longestBillingGracePeriod: TimeInterval = 28 * 24 * 60 * 60
    /// How soon the store reads the renewal status again when a subscription is listed past its
    /// expiration date but the end of its grace period could not be read.
    static let gracePeriodStatusRetry: TimeInterval = 60 * 60

    /// The value a cutoff has to be **after** for the free launch window to exist at all: the
    /// Unix epoch, 1970-01-01T00:00:00Z.
    ///
    /// The App Store opened on 2008-07-10 and `AppTransaction.originalPurchaseDate` is signed
    /// by Apple, so no Apple Account can have first downloaded an app at or before the epoch.
    /// A cutoff of this value therefore takes nobody in, under a comparison
    /// (`originalPurchaseDate < cutoff`) that no signed date can satisfy.
    static let launchWindowClosed = Date(timeIntervalSince1970: 0)

    /// The instant the app flips from free to freemium (monetization.md section 11).
    ///
    /// **The window is closed (owner decision of 2026-09-28).** It was 2026-10-15T12:00:00Z
    /// (owner decision of 2026-09-20, build/ui-requests.md item 16). App Review rejected
    /// version 1.0.6 under Guideline 2.1(b) because a reviewer, being inside that window, could
    /// reach none of the four products, so the window is set to `launchWindowClosed` and grants
    /// nobody. The app has never been on sale, so the cohort has no members and nobody is owed
    /// anything; monetization.md section 11 already said that if approval slipped past the
    /// cutoff "nobody is ever in the launch cohort and it ships straight into freemium".
    ///
    /// **Why the epoch and not a date a few days back.** An Apple Account whose
    /// `AppTransaction.originalPurchaseDate` is before this instant is a member, permanently, so
    /// the value has to be one no install can be before. A cutoff of "today" would still take in
    /// every TestFlight install of this app, the earliest of which is from 2026-09-18, and those
    /// installs are the ones App Review and the owner run. The epoch is before the App Store
    /// existed, so it takes in no install of any age. See `launchWindowClosed`.
    ///
    /// The mechanism around it is kept, so the window can be reopened by moving this one
    /// constant: `MonetizationLaunchCohort` still reads Apple's app transaction, still stores
    /// the verdict and still answers `MonetizationRules.launchWindowIsOpen(cutoff:)` with false
    /// while the cutoff is this value, which is what makes it grant nobody even on a device
    /// where an earlier build already stored a member verdict.
    ///
    /// Nothing compares this with the device clock. It is compared only with the date Apple
    /// signed into the app transaction, so moving the clock moves nothing.
    static let launchCohortCutoff = MonetizationRules.launchWindowClosed

    /// Whether `cutoff` leaves a free launch window open at all.
    ///
    /// False for `launchWindowClosed`, which is what the shipping build carries. While it is
    /// false nobody is a member, whatever an earlier build wrote into the Keychain, and
    /// `MonetizationLaunchCohort` neither reads that record nor asks Apple for the app
    /// transaction.
    static func launchWindowIsOpen(cutoff: Date = MonetizationRules.launchCohortCutoff) -> Bool {
        cutoff > launchWindowClosed
    }
}
