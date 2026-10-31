import ImageIO
import SwiftUI

struct WatchContentView: View {
    let model: WatchModel
    @State private var showsFullBoard = false
    @ScaledMetric(relativeTo: .title3) private var moveSymbolSize = 24
    @Environment(\.scenePhase) private var scenePhase
    private let ink = Color(red: 238 / 255, green: 234 / 255, blue: 224 / 255)
    private let accent = Color(red: 124 / 255, green: 148 / 255, blue: 1)

    var body: some View {
        let failure = model.failure
        VStack(spacing: 8) {
            // Keep the action outside scrolling content on every screen.
            analyzeButton
                .layoutPriority(1)
            ScrollView { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
        // Use more of the gap below the clock without covering the system controls.
        .padding(.top, -8)
        .overlay(alignment: .topLeading) { previewMarker.offset(y: -20) }
        .foregroundStyle(ink)
        .containerBackground(Color(red: 18 / 255, green: 17 / 255, blue: 14 / 255), for: .navigation)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setScenePhase(phase)
        }
        .onAppear {
            #if DEBUG
            if model.isPreview && ProcessInfo.processInfo.arguments.contains("-watchPreviewExpanded") {
                showsFullBoard = true
            }
            #endif
        }
        .fullScreenCover(isPresented: $showsFullBoard) {
            if let playback = model.displayedPlayback {
                GeometryReader { proxy in
                    Button { showsFullBoard = false } label: {
                        BoardMovePlaybackView(playback: playback, isPlaying: !model.isAnalyzing)
                            .opacity(model.isAnalyzing ? 0.35 : 1)
                            .padding(.top, 32)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .background(Color.black)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expanded chessboard")
                    .accessibilityHint("The move repeats. Tap to return to the result.")
                    .accessibilityAction(.escape) { showsFullBoard = false }
                }
                .ignoresSafeArea()
            } else if let image = boardImage {
                GeometryReader { proxy in
                    Button { showsFullBoard = false } label: {
                        Image(decorative: image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fit)
                            .opacity(model.isAnalyzing && !model.hasCurrentBoardPreview ? 0.35 : 1)
                            .padding(8)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .background(Color.black)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expanded chessboard")
                    .accessibilityHint("Tap to return to the result.")
                    .accessibilityAction(.escape) { showsFullBoard = false }
                }
                .ignoresSafeArea()
            }
        }
        .alert(errorTitle(failure), isPresented: Binding(
            get: { model.failure != nil },
            set: { if !$0, let id = failure?.id { model.dismissError(id: id) } }
        ), presenting: failure) { failure in
            Button("Try again") {
                model.retry(dismissing: failure.id)
            }
            Button("Close", role: .cancel) { model.dismissError(id: failure.id) }
        } message: { failure in
            Text(message(failure))
        }
    }

    private var analyzeButton: some View {
        Button(action: model.analyze) {
            ZStack {
                Text("Analyze Latest Screenshot")
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                // Preserve the full label's dimensions while the spinner replaces it.
                .opacity(model.isAnalyzing ? 0 : 1)
                if model.isAnalyzing {
                    ProgressView()
                        .fixedSize()
                        .tint(ink)
                        .accessibilityHidden(true)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(accent)
        .frame(maxWidth: .infinity, alignment: .center)
        .disabled(model.isAnalyzing)
        .accessibilityLabel("Analyze Latest Screenshot")
        .accessibilityValue(model.isAnalyzing
            ? (model.isReconnecting ? Text("Connecting to iPhone…") : Text("Analyzing on iPhone…"))
            : Text(""))
        .accessibilityIdentifier("watch.analyze")
    }

    private var content: some View {
        VStack(alignment: .center, spacing: model.reply == nil && model.boardPreview == nil ? 12 : 8) {
            if !model.isAnalyzing && !model.isActivated {
                Text("Connecting to iPhone…")
                Button("Reconnect", action: model.activate)
            } else if !model.isAnalyzing && model.reply == nil && model.boardPreview == nil {
                Text("New positions use one analysis or Pro access.")
                    .font(.footnote)
                    .foregroundStyle(ink.opacity(0.75))
                    .accessibilityIdentifier("watch.ready")
            }
            if model.reply != nil || model.hasBoard { result }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder private var previewMarker: some View {
        #if DEBUG
        if model.isPreview {
            Text("Preview")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #endif
    }

    @ViewBuilder private var result: some View {
        if model.hasBoard {
            // A move's wrapping must never resize or reposition the board.
            boardButton
                .frame(width: 88, height: 88)
                .frame(maxWidth: .infinity)
            moveLabel
            if model.showsCompletedMove, model.reply?.stealthMode == true {
                Text("Stealth Mode").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        } else if let reply = model.reply {
            Text(reply.status == .checkmate ? LocalizedStringKey("Checkmate") : LocalizedStringKey("Stalemate")).font(.headline)
        }
    }

    private var moveLabel: some View {
        HStack(alignment: .center, spacing: 6) {
            if let piece = model.reply?.playback?.steps.first?.moving.first?.piece {
                ChessPieceSymbol(piece: piece).frame(width: moveSymbolSize, height: moveSymbolSize)
            }
            if let text = model.moveDisplayFormat.text(words: model.reply?.moveDescription, notation: model.reply?.san) {
                Text(verbatim: text)
                    .font(model.moveDisplayFormat == .words ? .title3.bold() : .system(.title3, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
        }
        // Keep the last readout's space while a new crop replaces its board. Its old
        // move must not be shown or announced as an answer for that new image.
        .frame(maxWidth: .infinity, minHeight: moveSymbolSize, alignment: .center)
        .opacity(model.showsCompletedMove ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.reply?.moveDescription ?? model.reply?.san ?? ""))
        .accessibilityHidden(!model.showsCompletedMove)
    }

    @ViewBuilder private var boardButton: some View {
        if let image = boardImage {
            Button { showsFullBoard = true } label: {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .opacity(model.isAnalyzing && !model.hasCurrentBoardPreview ? 0.35 : 1)
            }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Expand chessboard")
                .accessibilityHint(model.displayedPlayback == nil || model.isAnalyzing
                    ? LocalizedStringKey("Shows the board full screen. Tap again to return.")
                    : LocalizedStringKey("Shows the board full screen and plays the move. Tap again to return."))
                .accessibilityIdentifier("watch.board")
        } else if let playback = model.displayedPlayback {
            Button { showsFullBoard = true } label: {
                BoardMovePlaybackView(playback: playback, isPlaying: false)
                    .opacity(model.isAnalyzing ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Expand chessboard")
            .accessibilityHint("Shows the board full screen and plays the move. Tap again to return.")
            .accessibilityIdentifier("watch.board")
        }
    }

    private var boardImage: CGImage? {
        guard let data = model.displayedThumbnail,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func message(_ failure: WatchRequestState.Failure) -> LocalizedStringKey {
        if failure.status == .unavailable, failure.origin == .phone {
            return "Your iPhone could not finish the analysis. Try again."
        }
        return switch failure.status {
        case .setupRequired: "Open Chess Best Move on iPhone and allow full Photos access to read new screenshots."
        case .noScreenshot: "No screenshot was found in your iPhone photo library. Take a screenshot, then tap Analyze again."
        case .needsCorrection: "This position needs confirmation. Open the screenshot in Chess Best Move on iPhone."
        case .noBoard: "No clear chessboard found. Take a screenshot showing the whole board."
        case .noCredits: "No analyses remaining. Open Chess Best Move on iPhone for Pro or more analyses."
        case .busy: "The iPhone app is busy. Leave Chess Best Move on iPhone, then try again."
        case .timedOut: "The iPhone did not finish in time. Open Chess Best Move on iPhone once, then try again."
        default: "Could not reach the iPhone app. Check the connection and open Chess Best Move on iPhone once."
        }
    }

    private func errorTitle(_ failure: WatchRequestState.Failure?) -> LocalizedStringKey {
        if failure?.status == .unavailable, failure?.origin == .phone {
            return "Could Not Analyze"
        }
        return switch failure?.status {
        case .noBoard: "No Chessboard Found"
        case .noScreenshot: "No Screenshot Found"
        case .setupRequired: "iPhone Setup Needed"
        case .needsCorrection: "Check the Position on iPhone"
        case .noCredits: "No Analyses Remaining"
        case .busy: "iPhone Is Busy"
        case .timedOut: "Analysis Timed Out"
        default: "Could Not Reach iPhone"
        }
    }
}
