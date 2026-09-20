import SwiftUI

/// The CreditsIndicator connected to the store and credits services. Place it in the
/// trailing toolbar of Home and Analysis. Hidden for Pro; at zero it opens the paywall.
///
/// At accessibility text sizes it draws nothing and `CreditsInlineIndicator` takes over inside
/// the screen's scrolling content. A navigation bar is a fixed-height strip that does not
/// scroll and is shared with the title and the gear button: "No free analyses" needs about
/// 390 pt at AccessibilityXXXL, so in the bar it truncated to an ellipsis from AccessibilityM
/// on and was clipped vertically above that. A free user could not read how many analyses were
/// left, and the same element is the button that opens the paywall at zero. Moving it into the
/// content is the only place it can have the room without being made smaller.
///
/// **The size is passed in and not read from the environment.** A toolbar item is hosted by the
/// navigation bar rather than by the content it is attached to, and it was handed the default
/// Dynamic Type size whatever the reader had asked for: measured on an iPhone 18 Pro (iOS 27.0)
/// at AccessibilityXXXL, a `@Environment(\.dynamicTypeSize)` read inside this view returned a
/// non-accessibility size, so the bar drew the indicator at its own small size while
/// `CreditsInlineIndicator` drew it again in the content, and the reader met the same paywall
/// button twice. The screen passes its own size, which is the one the reader asked for.
struct CreditsToolbarIndicator: View {
    /// The Dynamic Type size of the screen this toolbar belongs to.
    let dynamicTypeSize: DynamicTypeSize

    @Environment(AppModel.self) private var app

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
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
}

/// The CreditsIndicator inside a screen's scrolling content, which is where it lives at
/// accessibility text sizes (see `CreditsToolbarIndicator`). Draws nothing below those sizes,
/// so the indicator is never in two places at once.
struct CreditsInlineIndicator: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            CreditsIndicator(
                freeRemaining: app.credits.freeRemaining,
                freeAllowance: app.credits.freeAllowance,
                purchasedRemaining: app.credits.purchasedRemaining,
                isPro: app.store.isPro
            ) {
                app.presentPaywall(trigger: .creditsIndicator)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Spacing.s2)
        }
    }
}

/// The gear button that opens Settings.
///
/// The label is the symbol and nothing else, with no frame of its own. A toolbar item is given
/// its own Liquid Glass background, which hugs the label, adds its own padding and sets the
/// item's height from the bar rather than from the label. A 44 pt frame inside that widened the
/// glass without changing its height, which is what made it an oval: measured from a screenshot
/// on an iPhone 18 Pro (iOS 27.0), the glass was 57.33 x 45.33 pt with the frame and is
/// 45.33 x 45.33 pt without it. The item is still over the 44 pt minimum hit target, because the
/// bar's own height is what sets it (owner request, `build/ui-requests.md` item 11).
struct SettingsToolbarButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.presentSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Palette.ink)
        }
        .accessibilityLabel("Settings")
    }
}
