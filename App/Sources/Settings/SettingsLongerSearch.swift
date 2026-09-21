import SwiftUI

/// The two Pro settings for the search that keeps running after the first answer
/// (design.md sections 9.8 and 16, `build/ui-requests.md` items 8 and 9).
///
/// Both are shown to everybody. A free user sees them disabled, each carrying a `ProTag`,
/// rather than not seeing them at all: a setting nobody can find is not an offer, and hiding
/// them would leave the notice they do see ("Pro shows it") unexplained.
///
/// A reader who already has them sees neither the tag nor the footer, because neither says
/// anything to them: a Pro subscriber, and a member of the free launch cohort, for whom the
/// app carries no commercial surface at all (monetization.md section 11).
///
/// These are the second and third rows of the ANALYSIS card in Settings, so this view draws
/// rows and the separator between them and nothing else. The card's footer is
/// `SettingsLongerSearchFooter`, which sits under the card.
struct SettingsLongerSearchSection: View {
    @Environment(AppModel.self) private var app

    /// What the section says. Kept here so `AppCopyTests` and the settings tests read one place.
    enum Copy {
        static let title = "Keep searching after the answer"
        static let explanation =
            "The engine keeps searching the same board after the first move appears, and stops at this time at the latest. It stops earlier once the move has held for several depths, and right away when the device is saving power or has warmed up."
        static let ceilingLabel = "Longest search"
        static let automaticTitle = "Switch to a better move automatically"
        static let automaticExplanation =
            "With this off, a notice offers the move instead, so the move on screen does not change while you are reading it."

        /// The footer under the ANALYSIS card, for a free user only.
        ///
        /// It used to read "Both settings come with Pro.", which the `ProTag` on each row now
        /// says better: a footer cannot point at a row. So the footer stopped repeating it and
        /// says the two things the tags cannot (owner request of 2026-09-20, design.md 9.8):
        /// that the longer search runs for a free user too, at the default ceiling, and that a
        /// value saved now survives until Pro is bought.
        static func proFooter(_ ceiling: LongerSearchCeiling) -> String {
            "Without Pro the longer search still runs, stops at \(ceiling.spokenLabel), and says when it finds a better move. What you choose here is saved for when you get Pro."
        }
    }

    var body: some View {
        @Bindable var settings = app.settings
        let isPro = app.store.isPro
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                ProTaggedTitle(Copy.title, isMuted: !isPro, showsTag: !isPro)
                LongerSearchCeilingControl(selection: $settings.longerSearchCeiling)
                    .disabled(!isPro)
                Text(Copy.explanation)
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .groupedRow(verticalPadding: Spacing.s3)

            GroupedRowSeparator(start: .content)

            VStack(alignment: .leading, spacing: Spacing.s2) {
                AutomaticSwitchRow(isOn: $settings.switchesToBetterMoveAutomatically, isPro: isPro)
                Text(Copy.automaticExplanation)
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .groupedRow(verticalPadding: Spacing.s3)
        }
    }
}

/// The "Switch to a better move automatically" row: the title with its `ProTag`, and the
/// switch.
///
/// At accessibility text sizes the switch moves under the title instead of sitting beside it.
/// A switch is about 51 pt wide at every text size, and inside the card's 16 pt row inset that
/// leaves the title too little width for the word "automatically" at the largest size, which
/// SwiftUI then breaks in the middle ("automaticall" / "y"). Stacking gives the title the whole
/// width of the row. This is the same move `LongerSearchCeilingControl` makes with its
/// segmented control, and it reads the text size rather than measuring anything.
private struct AutomaticSwitchRow: View {
    @Binding var isOn: Bool
    let isPro: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// What VoiceOver says for the row, stacked or not: the title, then what the tag means.
    /// With the setting already unlocked there is no tag, so the label is the title alone.
    private var spokenLabel: String {
        isPro
            ? SettingsLongerSearchSection.Copy.automaticTitle
            : "\(SettingsLongerSearchSection.Copy.automaticTitle), \(ProTag.spokenLabel)"
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                // Drawn for the eye only: the switch under it carries the whole spoken label,
                // so VoiceOver reads the row once rather than as a title and then a switch.
                ProTaggedTitle(SettingsLongerSearchSection.Copy.automaticTitle, isMuted: !isPro, showsTag: !isPro)
                    .accessibilityHidden(true)
                toggle
                    .labelsHidden()
                    .accessibilityLabel(spokenLabel)
            }
        } else {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(isOn: $isOn) {
            ProTaggedTitle(SettingsLongerSearchSection.Copy.automaticTitle, isMuted: !isPro, showsTag: !isPro)
        }
        .tint(Palette.accent)
        .disabled(!isPro)
        .frame(minHeight: Layout.minimumHitTarget)
    }
}

/// The footer under the ANALYSIS card, present only for a free user.
struct SettingsLongerSearchFooter: View {
    @Environment(AppModel.self) private var app

    /// The identifier the settings UI tests look the line up by. It is unchanged from when the
    /// line read "Both settings come with Pro.", so a test that watches the free state keeps
    /// finding it.
    static let accessibilityIdentifier = "settings.longerSearchProOnly"

    @ViewBuilder
    var body: some View {
        if !app.store.isPro {
            GroupedFooter {
                Text(SettingsLongerSearchSection.Copy.proFooter(.defaultValue))
                    .accessibilityIdentifier(Self.accessibilityIdentifier)
            }
        }
    }
}

/// The ceiling picker: the segmented control of `ThinkTimeControl` with the four choices of
/// item 8 (15 s, 30 s, 1 min, 2 min). At accessibility text sizes it becomes a `Menu` showing
/// the value, so the four labels never have to fit side by side.
struct LongerSearchCeilingControl: View {
    @Binding var selection: LongerSearchCeiling

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    /// The control's own name, with what the tag on the title above it means when the control
    /// is disabled.
    ///
    /// The `ProTag` sits on the row's title, which is a separate element from this control, so
    /// a reader who landed on a segment heard "30 seconds, selected, dimmed" and was given no
    /// reason. The switch row below does this correctly, because there the tagged title IS the
    /// toggle's label; here the control has to say it itself (design.md 9.8).
    private var groupLabel: String {
        isEnabled
            ? SettingsLongerSearchSection.Copy.ceilingLabel
            : "\(SettingsLongerSearchSection.Copy.ceilingLabel), \(ProTag.spokenLabel)"
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                menu
                    .accessibilityLabel(groupLabel)
                    .accessibilityValue(selection.spokenLabel)
            } else {
                // The group label goes on a container, so each segment keeps its own label
                // ("30 seconds") instead of every segment reading "Longest search".
                segments
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(groupLabel)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(LongerSearchCeiling.allCases) { ceiling in
                let isSelected = ceiling == selection
                Button {
                    selection = ceiling
                } label: {
                    Text(ceiling.label)
                        .typography(.data)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(segmentInk(isSelected: isSelected))
                        .frame(maxWidth: .infinity, minHeight: Layout.chipHeight)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.r2 - 2, style: .continuous)
                                .fill(isSelected ? (isEnabled ? Palette.ink : Palette.ink3) : Color.clear)
                        )
                        .frame(minHeight: Layout.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel(ceiling.spokenLabel)
                // The segment reads "30 s" and is named "30 seconds"; Voice Control matches the
                // name, so the written form is given as an input label too.
                .accessibilityInputLabels([ceiling.label, ceiling.spokenLabel])
                // Said on the segment as well as on the group, because a reader may land on a
                // segment without entering through the group.
                .accessibilityHint(isEnabled ? "" : ProTag.spokenLabel)
            }
        }
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
                .fill(Palette.sunken)
                .frame(height: Layout.chipHeight + 4)
        )
    }

    /// The disabled control keeps its shape and its value, in muted ink: a free user can read
    /// which ceiling applies, and see that it is not theirs to change yet.
    private func segmentInk(isSelected: Bool) -> Color {
        if isSelected { return Palette.canvas }
        return isEnabled ? Palette.ink : Palette.ink3
    }

    private var menu: some View {
        Menu {
            Picker(SettingsLongerSearchSection.Copy.ceilingLabel, selection: $selection) {
                ForEach(LongerSearchCeiling.allCases) { ceiling in
                    Text(ceiling.label).tag(ceiling)
                }
            }
        } label: {
            HStack(spacing: Spacing.s2) {
                Text(selection.label).typography(.data)
                Image(systemName: "chevron.up.chevron.down")
            }
            .foregroundStyle(isEnabled ? Palette.ink : Palette.ink3)
            .padding(.horizontal, Spacing.s3)
            .frame(minHeight: Layout.minimumHitTarget)
            .background(RoundedRectangle(cornerRadius: Radius.r2, style: .continuous).fill(Palette.sunken))
        }
    }
}

private struct LongerSearchCeilingControlPreview: View {
    @State private var ceiling = LongerSearchCeiling.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            LongerSearchCeilingControl(selection: $ceiling)
            LongerSearchCeilingControl(selection: $ceiling).disabled(true)
            LongerSearchCeilingControl(selection: $ceiling).environment(\.dynamicTypeSize, .accessibility2)
        }
        .padding(Spacing.s4)
        .background(Palette.canvas)
    }
}

#Preview("Longest search") {
    LongerSearchCeilingControlPreview()
}
