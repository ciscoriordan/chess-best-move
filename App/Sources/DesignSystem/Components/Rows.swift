import SwiftUI

/// A 1 px `rule` hairline. `leadingInset` starts the line at a row's title edge.
struct Hairline: View {
    var leadingInset: CGFloat = 0
    var color: Color = Palette.rule
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: LineWidth.hairline(displayScale: displayScale))
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

/// Rows separated by hairlines, with no card, fill or shadow ("rules, not cards").
/// Hairlines are drawn between rows, and optionally above the first and below the last.
struct HairlineGroup<Data: RandomAccessCollection, ID: Hashable, Row: View>: View {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    var leadingInset: CGFloat = 0
    var outerRules = true
    let row: (Data.Element) -> Row

    init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        leadingInset: CGFloat = 0,
        outerRules: Bool = true,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.data = data
        self.id = id
        self.leadingInset = leadingInset
        self.outerRules = outerRules
        self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if outerRules { Hairline() }
            ForEach(Array(data.enumerated()), id: \.offset) { offset, element in
                if offset > 0 { Hairline(leadingInset: leadingInset) }
                row(element)
            }
            if outerRules { Hairline() }
        }
    }
}

extension HairlineGroup where Data.Element: Identifiable, ID == Data.Element.ID {
    init(
        _ data: Data,
        leadingInset: CGFloat = 0,
        outerRules: Bool = true,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.init(data, id: \.id, leadingInset: leadingInset, outerRules: outerRules, row: row)
    }
}

/// ListRow (design.md section 6): 56 pt minimum height, leading SF Symbol (20 pt, `ink`),
/// title `body`, optional trailing value `callout` in `ink2`, chevron when it navigates.
/// The symbols grow with the `body` text at larger text sizes.
/// Use it as the label of a `Button` or `NavigationLink` with `.buttonStyle(.listRow)`.
struct ListRow: View {
    let title: String
    var systemImage: String?
    var value: String?
    var showsChevron = false

    /// The icon column and the chevron at the default text size.
    static let iconSide: CGFloat = 20
    static let chevronSide: CGFloat = 14

    /// Leading inset of the hairline under a row with an icon at the default text size: where
    /// the title starts. Between rows, use `ListRowHairline`, which follows the text size.
    static let titleInsetWithIcon: CGFloat = iconSide + Spacing.s4

    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = ListRow.iconSide
    @ScaledMetric(relativeTo: .body) private var chevronSide: CGFloat = ListRow.chevronSide

    init(_ title: String, systemImage: String? = nil, value: String? = nil, showsChevron: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: Spacing.s4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: iconSide))
                    .foregroundStyle(Palette.ink)
                    .frame(width: iconSide)
                    .accessibilityHidden(true)
            }
            Text(title)
                .typography(.body)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value)
                    .typography(.callout)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.trailing)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: chevronSide, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Layout.listRowHeight)
        .contentShape(Rectangle())
    }
}

/// The hairline between rows with icons. It starts at the title's leading edge at every text
/// size, because the icon column grows with the text.
struct ListRowHairline: View {
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = ListRow.iconSide

    var body: some View {
        Hairline(leadingInset: iconSide + Spacing.s4)
    }
}

/// Pressed state for list rows: a `sunken` wash, no other decoration.
struct ListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.sunken : Color.clear)
    }
}

extension ButtonStyle where Self == ListRowButtonStyle {
    static var listRow: ListRowButtonStyle { ListRowButtonStyle() }
}

/// SectionLabel: `label` token in `ink2`, uppercase, 24 pt above and 8 pt below.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .typography(.label)
            .foregroundStyle(Palette.ink2)
            .padding(.top, Spacing.s5)
            .padding(.bottom, Spacing.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The pinned bottom action bar on `raised`, with a hairline on top. Attach with
/// `.safeAreaInset(edge: .bottom) { PinnedActionBar { ... } }`.
struct PinnedActionBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            content()
                .sideGutter()
                .padding(.vertical, Spacing.s3)
        }
        .background(Palette.raised.ignoresSafeArea(edges: .bottom))
    }
}

#Preview("Rows") {
    struct Item: Identifiable {
        let id: String
        let icon: String
        var value: String?
        var chevron = false
    }
    let items = [
        Item(id: "Choose from Photos", icon: "photo.on.rectangle", chevron: true),
        Item(id: "Paste image", icon: "doc.on.clipboard"),
        Item(id: "Set up the one-step Shortcut", icon: "bolt", chevron: true),
    ]
    return VStack(alignment: .leading, spacing: 0) {
        SectionLabel("How it works")
        HairlineGroup(items, leadingInset: ListRow.titleInsetWithIcon) { item in
            Button {} label: {
                ListRow(item.id, systemImage: item.icon, value: item.value, showsChevron: item.chevron)
            }
            .buttonStyle(.listRow)
        }
        SectionLabel("About")
        ListRow("Version", value: "1.0 (1)")
        Spacer()
    }
    .sideGutter()
    .background(Palette.canvas)
    .safeAreaInset(edge: .bottom) {
        PinnedActionBar {
            PrimaryButton("Think longer: 10\u{00A0}s") {}
        }
    }
}
