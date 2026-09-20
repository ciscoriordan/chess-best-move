import SwiftUI

/// The quiet notice that the longer search has something to say about the move on screen
/// (`build/ui-requests.md` item 8, design.md section 16).
///
/// It sits under the result readout and under the assumed-castling caution, and above the
/// monetization notices, so everything that qualifies the move on screen stays together and
/// nothing above it moves when the notice appears. `AnalysisView.readoutGroups` places it.
///
/// The four things it says are built by `AnalysisLongerSearchCopy` from the search's state and
/// the tier, so the words can be checked without building a view:
///
/// - **Pro, a different move preferred:** "A longer search prefers (glyph) Nf3." with a
///   "Show it" link. The badge does not change by itself unless the user turned automatic
///   switching on, because they may be reading or copying it.
/// - **Pro, that move now shown:** "A longer search preferred (glyph) Nf3, now shown."
/// - **Pro, the same move confirmed:** "A longer search still prefers this move.", in the
///   `caption` token rather than `callout`. It is reassurance, not news.
/// - **Free, a different move found:** "A longer search found a different move. Pro shows it."
///   with a "See Pro" link. The move is not named: naming it would be the Pro feature. What
///   says the move on screen is only the quick answer is the pill of `AnalysisReadoutContent`,
///   not a second label here.
///
/// Nothing here moves the move itself, and VoiceOver reads the sentence as words: the glyph is
/// never read as a symbol name (design.md 12).
struct AnalysisLongerSearchNotice: View {
    /// The screen's model. The notice reads the longer search's state from it and asks it to
    /// take the better move when the user says so.
    let model: AnalysisScreenModel

    /// Identifiers for UI tests and for the walkthrough.
    enum ID {
        static let notice = "analysis.longerSearchNotice"
        static let action = "analysis.longerSearchAction"
    }

    var body: some View {
        if let content = model.longerSearchNotice {
            VStack(alignment: .leading, spacing: 0) {
                sentence(content)
                if let title = content.actionTitle {
                    TextLink(title) {
                        model.longerSearchAction()
                    }
                    .accessibilityHint(content.actionHint ?? "")
                    .accessibilityIdentifier(ID.action)
                }
            }
            .padding(.bottom, Spacing.s3)
            .accessibilityIdentifier(ID.notice)
        }
    }

    /// The sentence, with the piece glyph next to the move it names (item 3). The confirmation
    /// carries no move and is a `caption`, which is what makes it subtler than the news.
    @ViewBuilder
    private func sentence(_ content: AnalysisLongerSearchNoticeContent) -> some View {
        Group {
            if let move = content.move {
                AnalysisGlyphLine(
                    prefix: content.sentencePrefix,
                    piece: move.piece,
                    text: move.san + content.sentenceSuffix,
                    spoken: content.spokenSentence
                )
            } else {
                Text(content.plainSentence)
                    .accessibilityLabel(content.spokenSentence)
            }
        }
        .typography(content.isSubtle ? .caption : .callout)
        .foregroundStyle(Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
