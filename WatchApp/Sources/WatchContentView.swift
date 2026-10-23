import ImageIO
import SwiftUI

struct WatchContentView: View {
    let model: WatchModel
    @State private var showsFullBoard = false
    @ScaledMetric(relativeTo: .title3) private var moveSymbolSize = 24
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let ink = Color(red: 238 / 255, green: 234 / 255, blue: 224 / 255)
    private let accent = Color(red: 124 / 255, green: 148 / 255, blue: 1)

    var body: some View {
        let failure = model.failure
        ScrollView {
            VStack(alignment: .leading, spacing: model.reply == nil ? 12 : 8) {
                Button(action: model.analyze) {
                    HStack(alignment: .center, spacing: 8) {
                        if dynamicTypeSize < .xxLarge {
                            Image(systemName: "viewfinder")
                                .accessibilityHidden(true)
                        }
                        Text("Analyze latest screenshot")
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        // Balance the decorative symbol so the words share the button's center.
                        if dynamicTypeSize < .xxLarge {
                            Image(systemName: "viewfinder")
                                .hidden()
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(model.isAnalyzing || !model.isActivated)
                .accessibilityIdentifier("watch.analyze")
                if model.isAnalyzing {
                    ProgressView(model.isWaitingForActivation
                        ? LocalizedStringKey("Connecting to iPhone…") : LocalizedStringKey("Analyzing on iPhone…"))
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if !model.isActivated {
                    Text("Connecting to iPhone…")
                    Button("Reconnect", action: model.activate)
                } else if model.reply == nil {
                    Text("New positions use one analysis or Pro access.")
                        .font(.footnote)
                        .foregroundStyle(ink.opacity(0.75))
                }
                if let reply = model.reply { result(reply) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .foregroundStyle(ink)
        .containerBackground(Color(red: 18 / 255, green: 17 / 255, blue: 14 / 255), for: .navigation)
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            if model.isPreview && ProcessInfo.processInfo.arguments.contains("-watchPreviewExpanded") {
                showsFullBoard = true
            }
            #endif
        }
        .fullScreenCover(isPresented: $showsFullBoard) {
            if let playback = model.reply?.playback {
                Button { showsFullBoard = false } label: {
                    BoardMovePlaybackView(playback: playback)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .ignoresSafeArea()
                .accessibilityLabel("Expanded chessboard")
                .accessibilityHint("The move repeats. Tap to return to the result.")
                .accessibilityAction(.escape) { showsFullBoard = false }
            } else if let image = boardImage {
                GeometryReader { proxy in
                    Button { showsFullBoard = false } label: {
                        Image(decorative: image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fit)
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
        .alert(errorTitle(failure?.status), isPresented: Binding(
            get: { model.failure != nil },
            set: { if !$0, let id = failure?.id { model.dismissError(id: id) } }
        ), presenting: failure) { failure in
            Button("Try again") {
                model.retry(dismissing: failure.id)
            }
            Button("Close", role: .cancel) { model.dismissError(id: failure.id) }
        } message: { failure in
            Text(message(failure.status))
        }
    }

    private var title: LocalizedStringKey {
        #if DEBUG
        if model.isPreview { return "Preview" }
        #endif
        return ""
    }

    @ViewBuilder private func result(_ reply: WatchAnalysisReply) -> some View {
        if reply.status == .result {
            HStack(alignment: .center, spacing: 6) {
                if let piece = reply.playback?.steps.first?.moving.first?.piece {
                    ChessPieceSymbol(piece: piece).frame(width: moveSymbolSize, height: moveSymbolSize)
                }
                if let text = model.moveDisplayFormat.text(words: reply.moveDescription, notation: reply.san) {
                    Text(verbatim: text)
                        .font(model.moveDisplayFormat == .words ? .title3.bold() : .system(.title3, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: reply.moveDescription ?? reply.san ?? ""))
            if let image = boardImage {
                Button { showsFullBoard = true } label: {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 88)
                }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Expand chessboard")
                    .accessibilityHint(reply.playback == nil
                        ? LocalizedStringKey("Shows the board full screen. Tap again to return.")
                        : LocalizedStringKey("Shows the board full screen and plays the move. Tap again to return."))
                    .accessibilityIdentifier("watch.board")
            } else if let playback = reply.playback {
                Button { showsFullBoard = true } label: {
                    BoardMovePlaybackView(playback: playback, isPlaying: false).frame(width: 88, height: 88)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Expand chessboard")
                .accessibilityHint("Shows the board full screen and plays the move. Tap again to return.")
                .accessibilityIdentifier("watch.board")
            }
        } else {
            Text(reply.status == .checkmate ? LocalizedStringKey("Checkmate") : LocalizedStringKey("Stalemate")).font(.headline)
        }
    }

    private var boardImage: CGImage? {
        guard let data = model.reply?.thumbnail,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func message(_ status: WatchAnalysisReply.Status) -> LocalizedStringKey {
        switch status {
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

    private func errorTitle(_ status: WatchAnalysisReply.Status?) -> LocalizedStringKey {
        switch status {
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
