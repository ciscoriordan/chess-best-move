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

    /// The instant the app flips from free to freemium (monetization.md section 11,
    /// build/ui-requests.md item 16, owner decision of 2026-09-20): **2026-10-15T12:00:00Z**.
    ///
    /// An Apple Account whose `AppTransaction.originalPurchaseDate` is before this instant is
    /// in the launch cohort, permanently; one at or after it meets the three free analyses and
    /// the paywall. It is a fixed boundary in the binary rather than a duration that starts at
    /// launch, so if the app is not on sale before it, nobody is ever in the launch cohort and
    /// it ships straight into freemium.
    ///
    /// **Why noon UTC and not midnight.** The promise is made to readers in local dates
    /// ("install before October 15, 2026"), and local dates run from UTC+14 to UTC-12. Noon
    /// UTC on 15 October is the last instant at which anywhere on Earth is still on 14
    /// October, so every reader who installs on a day they would call the 14th or earlier is
    /// inside the window. Erring later errs in the reader's favor; midnight UTC would have
    /// broken the promise for the eastern Pacific.
    ///
    /// Nothing compares this with the device clock. It is compared only with the date Apple
    /// signed into the app transaction, so moving the clock moves nothing.
    static let launchCohortCutoff = Date(timeIntervalSince1970: 1_792_065_600)
}
