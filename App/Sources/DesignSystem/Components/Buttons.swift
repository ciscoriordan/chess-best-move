import SwiftUI

/// PrimaryButton (design.md section 6): 52 pt tall, `r2`, `accent` fill, `button` label in
/// `onAccent`, optional leading SF Symbol. Pressed: `accentPressed` and scale 0.98 over
/// 90 ms. Disabled: `sunken` fill, `ink3` label. At most one per screen.
struct PrimaryButtonStyle: ButtonStyle {
    var minHeight: CGFloat = Layout.buttonHeight

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, minHeight: minHeight)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let minHeight: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .typography(.button)
                .foregroundStyle(isEnabled ? Palette.onAccent : Palette.ink3)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .padding(.horizontal, Spacing.s4)
                .background(
                    RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
                        .fill(fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.r2, style: .continuous))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: Motion.press), value: configuration.isPressed)
        }

        private var fill: Color {
            guard isEnabled else { return Palette.sunken }
            return configuration.isPressed ? Palette.accentPressed : Palette.accent
        }
    }
}

/// SecondaryButton: 52 pt (44 in dense rows), `r2`, 1 pt `rule2` border, no fill, `ink` label.
struct SecondaryButtonStyle: ButtonStyle {
    var dense = false

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, dense: dense)
    }

    private struct SecondaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let dense: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .typography(.button)
                .foregroundStyle(isEnabled ? Palette.ink : Palette.ink3)
                .frame(maxWidth: dense ? nil : .infinity, minHeight: dense ? Layout.denseButtonHeight : Layout.buttonHeight)
                .padding(.horizontal, Spacing.s4)
                .background(
                    RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
                        .fill(configuration.isPressed ? Palette.sunken : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
                        .strokeBorder(Palette.rule2, lineWidth: LineWidth.control)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.r2, style: .continuous))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: Motion.press), value: configuration.isPressed)
        }
    }
}

/// TextLink: `callout` in `ink2`, underlined, 44 pt tall hit area (Restore purchases,
/// Terms, Privacy).
struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typography(.callout)
            .underline()
            .foregroundStyle(Palette.ink2)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(minHeight: Layout.minimumHitTarget)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryDense: SecondaryButtonStyle { SecondaryButtonStyle(dense: true) }
}

extension ButtonStyle where Self == TextLinkStyle {
    static var textLink: TextLinkStyle { TextLinkStyle() }
}

/// A primary button with an optional leading SF Symbol at 17 pt.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s2) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 17, weight: .semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(.primary)
    }
}

/// A secondary button with an optional leading SF Symbol.
struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var dense = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, dense: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.dense = dense
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s2) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 17, weight: .regular))
                }
                Text(title)
            }
        }
        .buttonStyle(SecondaryButtonStyle(dense: dense))
    }
}

/// An underlined text link.
struct TextLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action).buttonStyle(.textLink)
    }
}

#Preview("Buttons") {
    VStack(alignment: .leading, spacing: Spacing.s3) {
        PrimaryButton("Analyze", systemImage: "sparkle.magnifyingglass") {}
        PrimaryButton("Analyze") {}.disabled(true)
        SecondaryButton("Choose another image") {}
        HStack {
            SecondaryButton("New", dense: true) {}
            Spacer()
        }
        HStack(spacing: Spacing.s2) {
            TextLink("Restore purchases") {}
            Text("·").foregroundStyle(Palette.ink3)
            TextLink("Terms") {}
            Text("·").foregroundStyle(Palette.ink3)
            TextLink("Privacy") {}
        }
    }
    .padding(Spacing.s4)
    .background(Palette.canvas)
}
