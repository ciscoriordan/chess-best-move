import ChessCore
import SwiftUI

/// Recognizing (design.md 9.2 and 11): the imported screenshot dimmed to 60% while the board
/// is found. Runs recognition through `app.recognition` and hands the outcome to
/// `app.handleRecognition(_:for:)`, which routes to Analysis, Check position or Board not
/// found.
///
/// When recognition returns a board:
/// 1. A 2 pt `accent` outline traces the found board rect (240 ms ease-out; at once with
///    Reduce Motion). Skipped when recognition finished within 150 ms of the screen appearing.
/// 2. The screenshot scales and crops into the board frame of the next screen (the
///    `Motion.boardCropSpring`, 320 ms, no bounce) while the rest of the screenshot fades out.
///    For Check position the board turns into the diagram with its marks on the way, because
///    that screen shows the recognized pieces. With Reduce Motion this is a 200 ms crossfade
///    in place.
/// 3. The next screen replaces this one without the navigation animation, with its board
///    exactly where this one came to rest.
///
/// A board whose analysis would open the paywall skips step 2 and routes with the normal
/// animation, so the paywall sheet still slides up over its board.
struct RecognizingView: View {
    let image: ImportedImage

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var appeared = false
    @State private var found: FoundBoard?
    @State private var outlineProgress: CGFloat = 0
    @State private var isLanded = false
    @State private var containerWidth: CGFloat = 0

    private static let coordinateSpace = "recognizing"

    /// The recognized board while it is outlined and landed.
    private struct FoundBoard: Equatable {
        /// In the screenshot's pixels.
        var pixelRect: CGRect
        var snapshot: BoardSnapshot
        /// Nil when the board is only outlined (the next screen opens with its normal
        /// animation).
        var destination: CaptureBoardLanding.Destination?
    }

    init(image: ImportedImage) {
        self.image = image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            GeometryReader { slot in
                stage(slot: slot.frame(in: .named(Self.coordinateSpace)))
            }
            HStack(spacing: Spacing.s2) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.ink2)
                Text("Finding the board...")
                    .typography(.callout)
                    .foregroundStyle(Palette.ink2)
            }
            .opacity(isLanded ? 0 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Finding the board")
        }
        .sideGutter()
        .padding(.vertical, Spacing.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
        .coordinateSpace(.named(Self.coordinateSpace))
        // While it scales up, the fading screenshot must not draw under the navigation bar.
        .clipped()
        .background(Palette.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.recognizingScreen)
        .sensoryFeedback(.impact(weight: .light), trigger: appeared) { _, new in new }
        .onAppear { appeared = true }
        .task(id: image.id) {
            await recognizeAndRoute()
        }
    }

    // MARK: Stage

    /// The screenshot, the found board and its outline, drawn in the image slot. `slot` is the
    /// slot's frame in the screen's coordinates; the landed board may lie outside the slot.
    @ViewBuilder
    private func stage(slot: CGRect) -> some View {
        let imageSize = CGSize(width: image.image.width, height: image.image.height)
        let resting = CaptureBoardLanding.restingImageFrame(imageSize: imageSize, in: slot.size)
        let shape = RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
        let found = found
        let board = found.map {
            CaptureBoardLanding.boardFrame(pixelRect: $0.pixelRect, imageSize: imageSize, imageFrame: resting)
        }
        let landing: CGRect? = found?.destination.map { destination in
            CaptureBoardLanding.boardFrame(for: destination, containerWidth: containerWidth)
                .offsetBy(dx: -slot.minX, dy: -slot.minY)
        }
        // Reduce Motion: nothing moves; the board crossfades in at its landing frame.
        let landed = isLanded && !reduceMotion
        let imageFrame = if landed, let board, let landing {
            CaptureBoardLanding.landedImageFrame(imageFrame: resting, board: board, landing: landing)
        } else {
            resting
        }
        let boardFrame = if let landing, landed || reduceMotion { landing } else { board ?? .zero }

        ZStack(alignment: .topLeading) {
            Image(decorative: image.image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .frame(width: imageFrame.width, height: imageFrame.height)
                .clipShape(shape)
                .opacity(isLanded ? 0 : 0.6)
                .offset(x: imageFrame.minX, y: imageFrame.minY)

            if let found, found.destination != nil {
                landingBoard(found)
                    .frame(width: boardFrame.width, height: boardFrame.height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Palette.rule2, lineWidth: LineWidth.hairline(displayScale: displayScale)))
                    .opacity(isLanded ? 1 : 0)
                    .offset(x: boardFrame.minX, y: boardFrame.minY)
            }

            if let board {
                let outlineFrame = landed ? boardFrame : board
                Rectangle()
                    .trim(from: 0, to: outlineProgress)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: LineWidth.selection, lineCap: .square))
                    .frame(width: outlineFrame.width, height: outlineFrame.height)
                    .opacity(isLanded ? 0 : 1)
                    .offset(x: outlineFrame.minX, y: outlineFrame.minY)
            }
        }
        .frame(width: slot.width, height: slot.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIgnoresInvertColors()
    }

    /// What the next screen shows in its board frame: the user's crop on Analysis, the
    /// recognized pieces with their marks on Check position.
    @ViewBuilder
    private func landingBoard(_ found: FoundBoard) -> some View {
        let snapshot = found.snapshot
        switch found.destination {
        case .checkPosition:
            ZStack {
                DiagramBoard(board: snapshot.position.board, whiteAtBottom: snapshot.whiteAtBottom)
                CaptureBoardMarks(
                    whiteAtBottom: snapshot.whiteAtBottom,
                    lowConfidence: snapshot.lowConfidenceSquares,
                    danger: CapturePositionIssues.dangerSquares(in: snapshot.position.validate())
                )
            }
        case .analysis, nil:
            if let crop = snapshot.boardImage {
                BoardScreenshot(image: crop, snapshot: snapshot)
            }
        }
    }

    // MARK: Recognition and handoff

    private func recognizeAndRoute() async {
        let shownAt = ContinuousClock.now
        found = nil
        outlineProgress = 0
        isLanded = false
        let outcome = await app.recognition.recognize(image)
        guard !Task.isCancelled else { return }

        let imageSize = CGSize(width: image.image.width, height: image.image.height)
        let recognized: (BoardSnapshot, CaptureBoardLanding.Destination)? = switch outcome {
        case .confident(let snapshot): (snapshot, .analysis)
        case .needsCheck(let snapshot): (snapshot, .checkPosition)
        case .boardNotFound, .invalidImage: nil
        }
        guard case let (snapshot, destination)? = recognized,
              let pixelRect = CaptureBoardLanding.usableBoardRect(snapshot.boardRect, imageSize: imageSize) else {
            await holdForDebugDelay(since: shownAt)
            guard !Task.isCancelled else { return }
            app.handleRecognition(outcome, for: image)
            return
        }

        let lands = destination == .checkPosition
            ? true
            : snapshot.boardImage != nil && analysisRunsWithoutPaywall(snapshot)
        found = FoundBoard(pixelRect: pixelRect, snapshot: snapshot, destination: lands ? destination : nil)

        // 1. Outline.
        let isFast = shownAt.duration(to: .now) < CaptureBoardLanding.skipOutlineWithin
        if !isFast || !lands {
            if reduceMotion {
                outlineProgress = 1
            } else {
                withAnimation(.easeOut(duration: Motion.stateLong)) { outlineProgress = 1 }
            }
            try? await Task.sleep(for: CaptureBoardLanding.outlineDuration)
            guard !Task.isCancelled else { return }
        }
        await holdForDebugDelay(since: shownAt)
        guard !Task.isCancelled else { return }

        guard lands else {
            app.handleRecognition(outcome, for: image)
            return
        }

        // 2. Crop into the next screen's board frame.
        if reduceMotion {
            withAnimation(.easeInOut(duration: CaptureBoardLanding.reducedMotionCrossfade)) { isLanded = true }
            try? await Task.sleep(for: .seconds(CaptureBoardLanding.reducedMotionCrossfade))
        } else {
            withAnimation(Motion.boardCropSpring) { isLanded = true }
            try? await Task.sleep(for: CaptureBoardLanding.cropSettle)
        }
        guard !Task.isCancelled else { return }

        // 3. The next screen takes over in place.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            app.handleRecognition(outcome, for: image)
        }
    }

    /// Whether `AppModel.handleRecognition` will start the analysis without presenting the
    /// paywall. `CreditsService.authorize` decides without spending; the origin mirrors
    /// `AppModel.handleRecognition`.
    private func analysisRunsWithoutPaywall(_ snapshot: BoardSnapshot) -> Bool {
        let origin: AnalysisOrigin = image.source == .shortcut ? .shortcut : .recognition
        return app.credits.authorize(board: snapshot.position.board, origin: origin,
                                     recognition: MonetizationRecognitionEvidence(snapshot)).decision.allowsAnalysis
    }

    /// DEBUG `-debugRecognitionDelay`: keeps Recognizing on screen for screenshots.
    private func holdForDebugDelay(since shownAt: ContinuousClock.Instant) async {
        #if DEBUG
        if let delay = DebugLaunchOptions.recognitionDelay {
            try? await Task.sleep(until: shownAt.advanced(by: delay), clock: .continuous)
        }
        #endif
    }
}

/// Board not found (design.md 9.5, second wireframe). Also explains an unreadable image and
/// a build without the recognition model. Never costs anything.
struct BoardNotFoundView: View {
    let image: ImportedImage

    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var appeared = false

    init(image: ImportedImage) {
        self.image = image
    }

    private var failure: CaptureRecognitionFailure {
        (app.recognition as? CaptureRecognitionService)?.failure(for: image.id) ?? .boardNotFound
    }

    var body: some View {
        let failure = failure
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(failure)
                Hairline()
                    .padding(.top, Spacing.s5)
                tips(failure)
                    .padding(.top, Spacing.s4)
                buttons(failure)
                    .padding(.top, Spacing.s6)
            }
            .sideGutter()
            .padding(.vertical, Spacing.s4)
        }
        .background(Palette.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.error, trigger: appeared) { _, new in new }
        .onAppear { appeared = true }
    }

    private func header(_ failure: CaptureRecognitionFailure) -> some View {
        let layout = dynamicTypeSize >= .accessibility1
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s4))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.s4))
        let shape = RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
        return layout {
            Image(decorative: image.image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 96, maxHeight: 144, alignment: .topLeading)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.rule2, lineWidth: LineWidth.control))
                .accessibilityIgnoresInvertColors()
            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(failure.title)
                    .typography(.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(CaptureAccessibilityID.boardNotFoundTitle)
                Text("This didn't use a free analysis.")
                    .typography(.callout)
                    .foregroundStyle(Palette.ink2)
            }
        }
    }

    private func tips(_ failure: CaptureRecognitionFailure) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            ForEach(failure.tips, id: \.self) { tip in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
                    Text("\u{2013}")
                        .typography(.body)
                        .foregroundStyle(Palette.ink2)
                        .accessibilityHidden(true)
                    Text(tip)
                        .typography(.body)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func buttons(_ failure: CaptureRecognitionFailure) -> some View {
        VStack(spacing: Spacing.s3) {
            if case .recognizerUnavailable = failure {
                PrimaryButton("Set up the position by hand") { setUpByHand() }
                SecondaryButton("Choose another image") { app.goHome() }
            } else {
                PrimaryButton("Choose another image") { app.goHome() }
                SecondaryButton("Set up the position by hand") { setUpByHand() }
            }
        }
    }

    private func setUpByHand() {
        app.presentEditor(EditorContext(
            snapshot: BoardSnapshot(position: .start, sideToMoveOrigin: .user),
            purpose: .handSetup
        ))
    }
}

extension CaptureRecognitionFailure {
    /// The Board not found screen title.
    var title: String {
        switch self {
        case .boardNotFound: "No board found"
        case .invalidImage: "Couldn't read this image"
        case .recognizerUnavailable: "Recognition isn't available"
        }
    }

    /// The bullet points under the title.
    var tips: [String] {
        switch self {
        case .boardNotFound:
            [
                "Use a screenshot of the board, not a photo of a screen.",
                "The whole board must be visible.",
                "Board themes with textures may not be recognized yet.",
            ]
        case .invalidImage:
            [
                "The file may be damaged, too small, or in a format this app can't open.",
                "Screenshots saved in Photos work best.",
            ]
        case .recognizerUnavailable:
            [
                "This copy of the app is missing its piece recognition model, so boards can't be read from images.",
                "You can still set up the position by hand and analyze it.",
            ]
        }
    }
}
