import SwiftUI

/// The CreditsIndicator connected to the store and credits services. Place it in the
/// trailing toolbar of Home and Analysis. Hidden for Pro; at zero it opens the paywall.
struct CreditsToolbarIndicator: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        CreditsIndicator(
            freeRemaining: app.credits.freeRemaining,
            freeAllowance: app.credits.freeAllowance,
            purchasedRemaining: app.credits.purchasedRemaining,
            isPro: app.store.isPro
        ) {
            app.presentPaywall(trigger: .creditsIndicator)
        }
    }
}

/// The gear button that opens Settings.
struct SettingsToolbarButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.presentSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Palette.ink)
                .frame(minWidth: Layout.minimumHitTarget, minHeight: Layout.minimumHitTarget)
        }
        .accessibilityLabel("Settings")
    }
}
