import SwiftUI

/// Metrics of the inset grouped card (design.md section 6).
enum GroupedList {
    /// Horizontal inset of a row's content from the card's edge. Together with the screen's
    /// side gutter this starts a row's content 32 or 36 pt from the screen edge, as an inset
    /// grouped list does; a title after the icon column starts 36 pt further in again.
    static let rowInset: CGFloat = Spacing.s4
    /// The card's corner radius.
    static let cornerRadius: CGFloat = Radius.r3
}

/// A group of rows drawn the way iOS draws an inset grouped list: one rounded `raised` card on
/// the `canvas` background, inset from the screen edges by the side gutter, with a 1 px `rule`
/// border and the rows clipped inside it.
///
/// This exists instead of a SwiftUI `List` because the screens that use it place the card
/// inside a `ScrollView` of their own. A `List` is its own scroll container, cannot be nested
/// in one, and has no way to push its rows to the bottom of the screen, which is where Home
/// needs them (design.md 9.1).
///
/// Put `GroupedRowSeparator` between rows and give each row `.groupedRow()`, which applies the
/// horizontal inset and makes the full width of the row tappable. Text that explains the group
/// goes under the card in a `GroupedFooter`, and the group's label goes above it in a
/// `GroupedSectionLabel`.
struct GroupedCard<Content: View>: View {
    @Environment(\.displayScale) private var displayScale
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GroupedList.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.rule, lineWidth: LineWidth.hairline(displayScale: displayScale)))
    }
}

/// The separator between two rows of a `GroupedCard`: a `rule` hairline that starts where the
/// row's content starts and runs to the card's trailing edge, as an inset grouped list insets
/// its separators.
///
/// Where the content starts depends on the rows around it. Rows with a leading icon start
/// their titles after the icon column, and the column grows with the `body` text, so that
/// inset follows the text size. Rows without an icon, which is every row in Settings, start
/// at the card's own row inset.
struct GroupedRowSeparator: View {
    /// Where the hairline begins.
    enum Start: Sendable, Hashable {
        /// At the card's row inset: for rows whose content has no leading icon column.
        case content
        /// After the leading icon column: for rows drawn as a `ListRow` with a `systemImage`.
        case title
    }

    var start: Start = .title

    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = ListRow.iconSide

    init(start: Start = .title) {
        self.start = start
    }

    var body: some View {
        Hairline(leadingInset: leadingInset)
    }

    private var leadingInset: CGFloat {
        switch start {
        case .content: GroupedList.rowInset
        case .title: GroupedList.rowInset + min(iconSide, Layout.maximumRowIcon) + Spacing.s4
        }
    }
}

/// The label above a `GroupedCard`: a `SectionLabel` moved in to the card's row content, the
/// way an inset grouped list lines a section header up with its rows rather than with the
/// card's edge.
///
/// Measured against a real `List(.insetGrouped)` on an iPhone 18 Pro (iOS 27.0): the system
/// header starts 32.33 pt from the screen edge and its row titles start 33.33 pt in, while a
/// `SectionLabel` on its own starts at the 16 pt side gutter. Use this wherever a label sits
/// above a card, and the plain `SectionLabel` everywhere else.
struct GroupedSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        SectionLabel(text)
            .padding(.horizontal, GroupedList.rowInset)
    }
}

/// The text under a `GroupedCard` that explains the group, the way an inset grouped list
/// explains a section: `caption` in `ink2`, aligned with the row content, 8 pt under the card.
///
/// Content that wants another color, such as an error line in `danger` or a `TextLink`, sets
/// its own and overrides the footer's.
struct GroupedFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            content
        }
        .typography(.caption)
        .foregroundStyle(Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GroupedList.rowInset)
        .padding(.top, Spacing.s2)
    }
}

extension GroupedFooter where Content == Text {
    /// A footer of one sentence.
    init(_ text: String) {
        self.init { Text(text) }
    }
}

/// The one primary action inside a `GroupedCard`, drawn as a filled row rather than as a
/// free-standing `PrimaryButton`: `accent` fill across the full width of the card, label in
/// `onAccent`, `accentPressed` while pressed, `sunken` with an `ink3` label when disabled.
///
/// It has no corner radius and no press scale of its own: the card clips it, so rounding it
/// again or shrinking it would show the card's fill along its edges.
struct GroupedPrimaryRowButtonStyle: ButtonStyle {
    var minHeight: CGFloat = Layout.listRowHeight

    func makeBody(configuration: Configuration) -> some View {
        GroupedPrimaryRowBody(configuration: configuration, minHeight: minHeight)
    }

    private struct GroupedPrimaryRowBody: View {
        let configuration: ButtonStyleConfiguration
        let minHeight: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .typography(.button)
                .foregroundStyle(isEnabled ? Palette.onAccent : Palette.ink3)
                .groupedRow(minHeight: minHeight)
                .background(fill)
        }

        private var fill: Color {
            guard isEnabled else { return Palette.sunken }
            return configuration.isPressed ? Palette.accentPressed : Palette.accent
        }
    }
}

extension ButtonStyle where Self == GroupedPrimaryRowButtonStyle {
    static var groupedPrimaryRow: GroupedPrimaryRowButtonStyle { GroupedPrimaryRowButtonStyle() }
}

extension View {
    /// Lays this view out as a row of a `GroupedCard`: the card's horizontal inset, at least
    /// the minimum row height, and a hit area over the whole width of the row.
    ///
    /// `verticalPadding` is for a row that is not a single line of text, such as a control with
    /// its own title and explanation above and below it (Settings > ANALYSIS). A `ListRow`
    /// leaves it at zero and takes its height from `minHeight`.
    ///
    /// `nonisolated` like SwiftUI's own modifiers, because `View` is a main-actor protocol and
    /// rows are built inside nonisolated label builders such as `PhotosPicker`'s.
    nonisolated func groupedRow(
        minHeight: CGFloat = Layout.listRowHeight,
        verticalPadding: CGFloat = 0
    ) -> some View {
        padding(.horizontal, GroupedList.rowInset)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}

#Preview("Grouped list") {
    VStack(alignment: .leading, spacing: 0) {
        GroupedSectionLabel("Import")
        GroupedCard {
            Button {} label: {
                HStack(spacing: Spacing.s3) {
                    RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
                        .fill(Palette.onAccent.opacity(0.2))
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use latest screenshot")
                        Text("Taken 12 seconds ago").typography(.caption).opacity(0.85)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Spacing.s2)
            }
            .buttonStyle(GroupedPrimaryRowButtonStyle(minHeight: 64))

            Button {} label: {
                ListRow("Choose from Photos", systemImage: "photo.on.rectangle", showsChevron: true).groupedRow()
            }
            .buttonStyle(.listRow)
            GroupedRowSeparator()
            Button {} label: {
                ListRow("Paste", systemImage: "doc.on.clipboard").groupedRow()
            }
            .buttonStyle(.listRow)
            GroupedRowSeparator()
            Button {} label: {
                ListRow("Set up the one-step Shortcut", systemImage: "bolt", showsChevron: true).groupedRow()
            }
            .buttonStyle(.listRow)
        }
        GroupedFooter("Limited access can't see new screenshots.")

        GroupedSectionLabel("Analysis")
        GroupedCard {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                ProTaggedTitle("Keep searching after the answer", isMuted: true)
                Text("The engine keeps searching the same board after the first move appears.")
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .groupedRow(verticalPadding: Spacing.s3)
            GroupedRowSeparator(start: .content)
            ListRow("Version", value: "1.0 (4)").groupedRow()
        }
        GroupedFooter("A footer explains the group, aligned with the row content.")
        Spacer()
    }
    .sideGutter()
    .background(Palette.canvas)
}
