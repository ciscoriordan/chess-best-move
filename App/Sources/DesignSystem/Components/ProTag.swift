import SwiftUI

/// The tag that marks one row, option or line as something the Pro tier unlocks
/// (design.md section 6).
///
/// It is the `label` token, so it is drawn in the same uppercase instrument lettering as
/// BEST MOVE, LINE and the section labels, in `accent` on `accentSubtle`. A disabled row is
/// drawn in muted ink, and a muted tag on a muted row would say nothing; the tag is the one
/// thing on such a row that keeps its color, which is what makes it readable as an offer
/// rather than as a control that happens to be off.
///
/// VoiceOver reads the tag as a whole statement ("Comes with Pro"), not as the three letters,
/// so a row that carries it explains itself without the reader having to know the convention.
/// Use `ProTaggedTitle` to put it after a row title as one VoiceOver element.
///
/// The tier is called Pro in the app and in the store, never "Plus" (design.md 14).
struct ProTag: View {
    /// The letters on screen. The `label` token uppercases them.
    static let title = "Pro"
    /// What VoiceOver says instead of reading the letters.
    static let spokenLabel = "Comes with Pro"

    /// Horizontal and vertical padding around the letters. Small enough that the tag sits on
    /// one line of `body` text without changing the row's height.
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 2

    var body: some View {
        Text(Self.title)
            .typography(.label)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
                    .fill(Palette.accentSubtle)
            )
            .accessibilityLabel(Self.spokenLabel)
    }
}

/// A row title followed by a `ProTag`, read by VoiceOver as one element: "Keep searching after
/// the answer, Comes with Pro".
///
/// At accessibility text sizes the tag moves above the title instead of sitting beside it. A
/// title at those sizes wraps over several lines, and a tag holding 40 pt of the row's width
/// would squeeze it further for no gain.
struct ProTaggedTitle: View {
    let title: String
    /// `true` on a row whose control is disabled, which draws the title in `ink2` the way the
    /// disabled control below it is drawn. The tag keeps its own color either way.
    var isMuted = false
    /// `false` draws the title alone. The tag is an offer, so it goes away for a reader who
    /// already has the thing: a Pro subscriber, and a member of the free launch cohort, who
    /// must be shown no Pro row at all (monetization.md section 11).
    var showsTag = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, isMuted: Bool = false, showsTag: Bool = true) {
        self.title = title
        self.isMuted = isMuted
        self.showsTag = showsTag
    }

    var body: some View {
        Group {
            if !showsTag {
                titleText
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    ProTag()
                    titleText
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
                    titleText
                    ProTag()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .typography(.body)
            .foregroundStyle(isMuted ? Palette.ink2 : Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Pro tag") {
    VStack(alignment: .leading, spacing: Spacing.s4) {
        ProTag()
        ProTaggedTitle("Keep searching after the answer")
        ProTaggedTitle("Switch to a better move automatically", isMuted: true)
        ProTaggedTitle("Switch to a better move automatically", isMuted: true)
            .environment(\.dynamicTypeSize, .accessibility2)
    }
    .padding(Spacing.s4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.canvas)
}
