import SwiftUI

// The horizontal inset of a row's content from the card's edge, which is the edge of the screen
// or of the container the card spans, is the side gutter for the window's width (16 pt on phones
// up to 402 pt wide, 20 pt above), so a row title starts on the same line as the screen's other
// text, its section label and its footer. A title after the icon column starts 36 pt further in
// again. Everything here reads it from `EnvironmentValues.sideGutterWidth`, which is the one
// definition (`Metrics.swift`).

/// A group of rows drawn the way iOS draws a plain grouped list (owner decision of 2026-09-22,
/// design.md section 6): one `raised` band on the `canvas` background that spans the full width
/// of its container, with a 1 px `rule` hairline along its top and its bottom, square ends and
/// no border at the sides.
///
/// It spans the container by undoing the side gutter it sits in (`ignoresSideGutter()`), so a
/// screen keeps one `sideGutter()` around all of its content and the card still reaches both
/// screen edges. In the pinned bar, which applies its gutter to its buttons only, and in a
/// column of a two-column layout there is no gutter to undo, and it spans the bar or the column.
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
    /// False for a card placed directly under a hairline that already draws its top edge: the
    /// pinned bar's own (the new-screenshot row, design.md 9.4). Two rules a pixel apart would
    /// draw one line twice as heavy as every other.
    let drawsTopRule: Bool
    let content: Content

    init(drawsTopRule: Bool = true, @ViewBuilder content: () -> Content) {
        self.drawsTopRule = drawsTopRule
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if drawsTopRule { Hairline() }
            content
            Hairline()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised)
        .ignoresSideGutter()
    }
}

/// The separator between two rows of a `GroupedCard`: a `rule` hairline that starts where the
/// row's content starts and runs to the card's trailing edge, which is the trailing edge of the
/// screen or of the container, as a grouped list insets its separators.
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
    @Environment(\.sideGutterWidth) private var rowInset

    init(start: Start = .title) {
        self.start = start
    }

    var body: some View {
        Hairline(leadingInset: leadingInset)
    }

    private var leadingInset: CGFloat {
        switch start {
        case .content: rowInset
        case .title: rowInset + min(iconSide, Layout.maximumRowIcon) + Spacing.s4
        }
    }
}

/// How far a GroupedSectionLabel or a GroupedFooter moves its text in so that it starts where the
/// card's rows start their content.
///
/// On a screen with a side gutter the text is already there: the gutter and the row inset are the
/// same width, so this is zero and the label sits where every other SectionLabel on the screen
/// does. It is the row inset only where the card spans a container with no gutter of its own,
/// which matches what `groupedRow()` does in that container.
///
/// Every label and footer in the app today sits on a screen with a gutter, so this adds nothing
/// anywhere: the one container without a gutter is the readout column of the two-column Analysis
/// layout, where no label or footer is drawn. It is kept so a label above a card keeps its
/// alignment wherever the card is placed.
private struct GroupedTextInset: ViewModifier {
    @Environment(\.sideGutterWidth) private var rowInset
    @Environment(\.enclosingSideGutter) private var enclosingGutter

    func body(content: Content) -> some View {
        content.padding(.horizontal, max(0, rowInset - enclosingGutter))
    }
}

/// The label above a `GroupedCard`: a `SectionLabel` lined up with the card's row content, the
/// way a grouped list lines a section header up with its rows.
///
/// With the card spanning the screen and its rows inset by the side gutter, that is where a plain
/// `SectionLabel` already is (design.md section 6, owner decision of 2026-09-22). This type stays
/// so the label above a card keeps that alignment wherever the card is placed, including in a
/// container without a gutter; use it wherever a label sits above a card, and the plain
/// `SectionLabel` everywhere else.
struct GroupedSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        SectionLabel(text)
            .modifier(GroupedTextInset())
    }
}

/// The text under a `GroupedCard` that explains the group, the way a grouped list explains a
/// section: `caption` in `ink2`, aligned with the row content, 8 pt under the card.
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
        .modifier(GroupedTextInset())
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
/// free-standing `PrimaryButton`: `accent` fill across the full width of the card, which is the
/// full width of the screen, label in `onAccent`, `accentPressed` while pressed, `sunken` with an
/// `ink3` label when disabled.
///
/// It has no corner radius and no press scale of its own: the card's ends are square, and a row
/// that rounded or shrank would show the card's fill along its edges.
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

/// `groupedRow(minHeight:verticalPadding:)`: the row inset is read from the environment, because
/// it is the side gutter of the window, which depends on the window's width.
private struct GroupedRowModifier: ViewModifier {
    let minHeight: CGFloat
    let verticalPadding: CGFloat

    @Environment(\.sideGutterWidth) private var rowInset

    nonisolated init(minHeight: CGFloat, verticalPadding: CGFloat) {
        self.minHeight = minHeight
        self.verticalPadding = verticalPadding
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, rowInset)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Lays this view out as a row of a `GroupedCard`: the card's horizontal inset (the side
    /// gutter, so the row's content starts on the screen's text line), at least the minimum row
    /// height, and a hit area over the whole width of the row, which is the width of the screen.
    ///
    /// The inset is measured from the band's own edge, so in a container narrower than the
    /// screen, which is the readout column of the two-column Analysis layout, the row's content
    /// starts a gutter inside the column rather than on the column's own text line (design.md
    /// section 6).
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
        modifier(GroupedRowModifier(minHeight: minHeight, verticalPadding: verticalPadding))
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
            // A stand-in for Home's paste row, which is the system paste control and not a
            // ListRow: the control draws its own icon and is placed by it, so the icon column is
            // not the same question there (design.md 9.1). Whether that row lines up has to be
            // looked at on Home.
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
