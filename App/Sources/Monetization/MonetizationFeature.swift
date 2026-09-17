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
    /// The live store: StoreKit 2 through `MonetizationLiveStoreKitClient`.
    @MainActor
    static func makeStoreService() -> any StoreService {
        #if DEBUG
        if MonetizationDebugOptions.demoFreeRemaining != nil {
            let defaults = MonetizationDebugOptions.demoDefaults
            // The scripted StoreKit starts empty at every launch; a Pro state cached by an earlier
            // launch would contradict it.
            MonetizationStoreService.forgetCachedEntitlements(in: defaults)
            return MonetizationStoreService(
                client: MonetizationDebugOptions.makeDemoClient(),
                defaults: defaults
            )
        }
        #endif
        return MonetizationStoreService(client: MonetizationLiveStoreKitClient())
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
    /// A board that differs from a paid board by at most this many squares is free, unless legal
    /// play from the paid board explains the change (`MonetizationPlayRule`). Taking exactly one
    /// piece off is free whether or not play explains it (`MonetizationCreditPolicy`).
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
}
