import SwiftUI

/// NewScreenshotRow (design.md section 6, 9.4 and 9.5; owner decision of 2026-09-21): a
/// screenshot the user took while away from the app, offered on the Analysis result and on Check
/// position. A GroupedCard holding one row: the thumbnail, "New screenshot" over its age, and a
/// dense SecondaryButton "Analyze" that imports it in place of the board on screen.
///
/// A screen places it twice and applies `offersNewScreenshot()` to its root. `.pinnedBar` goes
/// in the `top` of the screen's PinnedActionBar, above its buttons, and draws below the
/// accessibility text sizes; `.scrollingContent` goes at the top of the scrolling content and
/// draws at AX1 and up, where the bar would otherwise cover the screen. Each draws nothing unless
/// it applies, and both draw nothing without the modifier (previews, the design gallery).
///
/// Like every GroupedCard it spans its container edge to edge (owner decision of 2026-09-22):
/// the bar, whose hairline is the card's top edge, or the screen, or the readout column of the
/// two-column Analysis layout.
///
/// VoiceOver meets the row as one element, its Analyze button, so the element VoiceOver focuses
/// is the control a finger taps, and Voice Control, Switch Control and a keyboard reach the same
/// button.
struct NewScreenshotRow: View {
    enum Placement: Sendable, Hashable {
        /// Above the buttons of the pinned bar, below the accessibility text sizes.
        case pinnedBar
        /// At the top of the scrolling content, at the accessibility text sizes.
        case scrollingContent
    }

    /// The scroll target of the row at the top of the scrolling content.
    static let revealAnchor = "newScreenshot.reveal"
    /// Home's thumbnail side, at every text size (design.md section 6).
    static let thumbnailSide: CGFloat = 48

    let placement: Placement

    @Environment(CaptureNewScreenshotOfferModel.self) private var model: CaptureNewScreenshotOfferModel?
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// The card's row inset, the side gutter, which depends on the window's width.
    @Environment(\.sideGutterWidth) private var rowInset

    init(placement: Placement) {
        self.placement = placement
    }

    var body: some View {
        if let model, let offer = model.offer, applies(to: model) {
            card(model, offer)
                // The pinned bar's growth is animated by the modifier on the screen's root; the
                // row fades in over it, and still fades, faster, with Reduce Motion (design.md 11).
                .transition(.opacity.animation(.easeOut(duration: reduceMotion ? Motion.valueChange : Motion.stateLong)))
        }
    }

    private func applies(to model: CaptureNewScreenshotOfferModel) -> Bool {
        switch placement {
        case .pinnedBar: !dynamicTypeSize.isAccessibilitySize
        case .scrollingContent: dynamicTypeSize.isAccessibilitySize && model.isShownAtTop
        }
    }

    // MARK: Card

    @ViewBuilder
    private func card(_ model: CaptureNewScreenshotOfferModel, _ offer: CaptureNewScreenshotOfferModel.Offer) -> some View {
        let identifier = offer.asset.localIdentifier
        let key = AnnouncementKey(
            identifier: identifier,
            isCovered: app.sheet != nil || app.editor != nil || scenePhase != .active
        )
        // The age counts once a second, in the words and in the button's VoiceOver value alike.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            switch placement {
            case .pinnedBar:
                // The bar's hairline is the card's top edge, and the bar's own 12 pt above its
                // buttons is the gap under the card.
                GroupedCard(drawsTopRule: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The error is outside what `ViewThatFits` measures: a sentence that long
                        // never fits beside the button, and switching layouts would rebuild the
                        // button and lose VoiceOver and keyboard focus on every failed try.
                        ViewThatFits(in: .horizontal) {
                            inlineRow(model, offer, now: timeline.date)
                            wrappedRow(model, offer, now: timeline.date)
                        }
                        if let error = model.importError {
                            errorLine(error)
                                .padding(.leading, rowInset + Self.thumbnailSide + Spacing.s3)
                                .padding(.trailing, rowInset)
                                .padding(.bottom, Spacing.s2)
                        }
                    }
                }
            case .scrollingContent:
                GroupedCard {
                    VStack(alignment: .leading, spacing: Spacing.s3) {
                        tile(offer.thumbnail)
                        words(offer, now: timeline.date, wraps: true)
                        analyzeButton(model, offer, now: timeline.date, dense: false)
                        // Under the button, as in the pinned bar: above it, a failed tap moved
                        // the button it was made on down by the sentence's height, which at these
                        // sizes put it under the pinned bar.
                        if let error = model.importError {
                            errorLine(error)
                        }
                    }
                    .newScreenshotRowInsets(rowInset, verticalPadding: Spacing.s3)
                }
                .id(Self.revealAnchor)
                .padding(.bottom, Spacing.s5)
            }
        }
        .onChange(of: identifier, initial: true) { _, identifier in
            model.rowShown(identifier, placement: placement)
        }
        // Announced a second after it is drawn, which lets an image arriving from the share sheet
        // replace the screen first; the model posts it at low priority, so it waits for what
        // VoiceOver says by itself when the app comes back. Never under the editor or a sheet,
        // nor while the app is not active, where it would be spoken over another app and then
        // count as said: when that ends instead.
        .task(id: key) {
            guard !key.isCovered else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            model.announceIfDue(key.identifier, placement: placement)
        }
    }

    /// The title and the age on one line each, beside the button. Chosen while it fits, judged
    /// against the widest age the row can show, so the button does not jump between beside and
    /// under the words as the age counts. The words take the width the button leaves, so the
    /// gap between them is the stack's 12 pt at least, and no more is asked for.
    private func inlineRow(_ model: CaptureNewScreenshotOfferModel, _ offer: CaptureNewScreenshotOfferModel.Offer, now: Date) -> some View {
        HStack(spacing: Spacing.s3) {
            tile(offer.thumbnail)
            words(offer, now: now, wraps: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            analyzeButton(model, offer, now: now, dense: true)
        }
        .newScreenshotRowInsets(rowInset, verticalPadding: Spacing.s2)
    }

    /// The button under the words, which wrap between words, for a width the inline row does not
    /// fit (a narrow iPad window, the largest sizes below the accessibility sizes).
    private func wrappedRow(_ model: CaptureNewScreenshotOfferModel, _ offer: CaptureNewScreenshotOfferModel.Offer, now: Date) -> some View {
        HStack(alignment: .top, spacing: Spacing.s3) {
            tile(offer.thumbnail)
            VStack(alignment: .leading, spacing: Spacing.s2) {
                words(offer, now: now, wraps: true)
                analyzeButton(model, offer, now: now, dense: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .newScreenshotRowInsets(rowInset, verticalPadding: Spacing.s2)
    }

    // MARK: Pieces

    /// "New screenshot" over "Taken 8 s ago". Hidden from VoiceOver: the button says all of it.
    private func words(_ offer: CaptureNewScreenshotOfferModel.Offer, now: Date, wraps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CaptureNewScreenshotCopy.title)
                .typography(.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: !wraps, vertical: wraps)
            if wraps {
                ageLine(offer, now: now)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Laid out over the widest age, which is drawn but never seen. Digits of one
                // width make an age no wider than the template with as many characters.
                ZStack(alignment: .leading) {
                    Text(CaptureNewScreenshotCopy.widestAge)
                        .monospacedDigit()
                        .typography(.caption)
                        .hidden()
                    ageLine(offer, now: now)
                }
                .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func ageLine(_ offer: CaptureNewScreenshotOfferModel.Offer, now: Date) -> some View {
        if let date = offer.asset.creationDate {
            Text(CaptureNewScreenshotCopy.age(since: date, now: now))
                .monospacedDigit()
                .typography(.caption)
                .foregroundStyle(Palette.ink2)
        }
    }

    /// "Couldn't open this screenshot. ..." in `danger`, the last line of the card, until the next
    /// offer or tap. Hidden from VoiceOver: it is the button's value, and the model announces it.
    private func errorLine(_ error: String) -> some View {
        Text(error)
            .typography(.caption)
            .foregroundStyle(Palette.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }

    /// Home's thumbnail tile: 48 x 48 pt at every text size, the screenshot cropped to fill,
    /// with a `rule2` border because it sits on `raised` rather than on Home's cobalt fill.
    private func tile(_ thumbnail: CGImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
        let side = Self.thumbnailSide
        return Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(shape)
                    .accessibilityIgnoresInvertColors()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: side * 0.58, weight: .regular))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: side, height: side)
                    .background(Palette.sunken, in: shape)
            }
        }
        .overlay(shape.strokeBorder(Palette.rule2, lineWidth: LineWidth.control))
        .accessibilityHidden(true)
    }

    /// The row's one control. While the screenshot is read, a progress indicator takes the place
    /// of the label at the same width.
    private func analyzeButton(
        _ model: CaptureNewScreenshotOfferModel,
        _ offer: CaptureNewScreenshotOfferModel.Offer,
        now: Date,
        dense: Bool
    ) -> some View {
        Button {
            // What the tap was made on is read now, before anything queued behind it runs, and a
            // tap that arrives while an import runs changes nothing, not even the DEBUG timeline.
            guard let screen = model.beginAnalyze(app: app) else { return }
            #if DEBUG
            DebugTimeline.shared.begin("newScreenshotTap")
            #endif
            Task { await model.analyzeOffer(app: app, tappedOn: screen) }
        } label: {
            Text(CaptureNewScreenshotCopy.button)
                .opacity(model.isImporting ? 0 : 1)
                .overlay {
                    if model.isImporting {
                        ProgressView()
                            .tint(Palette.ink2)
                    }
                }
        }
        .buttonStyle(SecondaryButtonStyle(dense: dense))
        .disabled(model.isImporting)
        .accessibilityLabel(CaptureNewScreenshotCopy.accessibilityLabel)
        .accessibilityValue(spokenValue(model, offer, now: now))
        .accessibilityHint(CaptureNewScreenshotCopy.hint)
        .accessibilityInputLabels(CaptureNewScreenshotCopy.inputLabels)
        .accessibilityIdentifier(CaptureAccessibilityID.newScreenshotAnalyze)
    }

    private func spokenValue(_ model: CaptureNewScreenshotOfferModel, _ offer: CaptureNewScreenshotOfferModel.Offer, now: Date) -> String {
        if let error = model.importError { return error }
        if model.isImporting { return CaptureNewScreenshotCopy.importing }
        guard let date = offer.asset.creationDate else { return "" }
        return CaptureNewScreenshotCopy.spokenAge(since: date, now: now)
    }

    private struct AnnouncementKey: Hashable {
        let identifier: String
        let isCovered: Bool
    }
}

private extension View {
    /// `groupedRow`'s inset and 64 pt minimum height, without its hit area over the whole row.
    /// That hit area is for a row that is one button. This row's only control is Analyze, and
    /// with everything else in it hidden from VoiceOver the whole-row shape also becomes
    /// Analyze's accessibility frame: the focus ring, Voice Control's label and the point a
    /// tap on the element lands on were the whole row, and that point is on the words, where a
    /// tap does nothing (measured with a UI test, 2026-09-22).
    func newScreenshotRowInsets(_ rowInset: CGFloat, verticalPadding: CGFloat) -> some View {
        padding(.horizontal, rowInset)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
}

/// Owns a screen's `CaptureNewScreenshotOfferModel` and runs its checks: when the screen
/// appears (and appears again after the editor), when the app comes back, and on every photo
/// library change while the screen is up. Hands the model to the screen's two
/// `NewScreenshotRow`s through the environment.
///
/// The model lives here and not in the row because the row changes place at the accessibility
/// sizes, which would reset state the row held. It is created once, in `.task`: a `@State`
/// default is evaluated every time the modifier is re-created, which on Analysis is every engine
/// update. The `ScrollViewReader` is here because it must enclose the screen's `ScrollView`.
private struct CaptureNewScreenshotOfferModifier: ViewModifier {
    @State private var model: CaptureNewScreenshotOfferModel?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(model)
                // The pinned bar grows to hold the row, and the scroll view's bottom inset with
                // it; both are above the row, so the animation is applied here (design.md 11).
                .animation(reduceMotion ? nil : .easeOut(duration: Motion.stateLong), value: model?.offer?.asset)
                // Whether the reader is at the top of the screen's scroll view, for a row that
                // arrives while the reader is further down (design.md 9.4, "Where").
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top <= 1
                } action: { _, isAtTop in
                    model?.scrolledToTop(isAtTop)
                }
                .task {
                    let model = self.model ?? CaptureNewScreenshotOfferModel.forScreen()
                    if self.model == nil { self.model = model }
                    model.screenAppeared()
                    await model.watchLibrary()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, let model else { return }
                    model.returned()
                    Task { await model.refresh(.returned) }
                }
                .onChange(of: model?.revealTarget) { _, target in
                    guard target != nil else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.stateLong)) {
                        proxy.scrollTo(NewScreenshotRow.revealAnchor, anchor: .top)
                    }
                    model?.revealHandled()
                }
        }
    }
}

extension View {
    /// Offers a screenshot the user took while away (design.md 9.4). Apply to the root of a
    /// screen that places `NewScreenshotRow`, after its `.safeAreaInset`.
    func offersNewScreenshot() -> some View {
        modifier(CaptureNewScreenshotOfferModifier())
    }
}
