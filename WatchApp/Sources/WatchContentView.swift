import ImageIO
import SwiftUI

struct WatchContentView: View {
    let model: WatchModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let ink = Color(red: 238 / 255, green: 234 / 255, blue: 224 / 255)
    private let accent = Color(red: 124 / 255, green: 148 / 255, blue: 1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: model.reply == nil ? 12 : 8) {
                if let reply = model.reply { result(reply) }
                if model.isAnalyzing {
                    ProgressView("Analyzing on iPhone…")
                        .accessibilityLabel(Text("Analyzing on iPhone…"))
                } else if !model.isActivated {
                    Text("Connecting to iPhone…")
                    Button("Reconnect", action: model.activate)
                } else {
                    if let error = model.error { Text(message(error)).font(.body) }
                    Button(action: model.analyze) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "viewfinder")
                                .accessibilityHidden(true)
                            Text("Analyze latest screenshot")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tint(accent)
                    Text("Take a new screenshot on iPhone first.")
                        .font(.footnote)
                        .foregroundStyle(ink.opacity(0.75))
                    Text("Uses one analysis or Pro access. Reanalysis may be free.")
                        .font(.footnote)
                        .foregroundStyle(ink.opacity(0.75))
                    Text("For puzzles, study, and reviewing games.")
                        .font(.footnote)
                        .foregroundStyle(ink.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .foregroundStyle(ink)
        .containerBackground(Color(red: 18 / 255, green: 17 / 255, blue: 14 / 255), for: .navigation)
        .navigationTitle(title)
        .toolbarTitleDisplayMode(model.reply == nil && dynamicTypeSize <= .large ? .automatic : .inline)
    }

    private var title: LocalizedStringKey {
        #if DEBUG
        if model.isPreview { return "Preview" }
        #endif
        return "Best Move"
    }

    @ViewBuilder private func result(_ reply: WatchAnalysisReply) -> some View {
        if let date = reply.screenshotDate {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    if context.date.timeIntervalSince(date) > WatchWire.screenshotMaximumAge {
                        Text("Previous result")
                    }
                    HStack(alignment: .firstTextBaseline) {
                        if let white = reply.whiteToMove {
                            Text(white ? LocalizedStringKey("White to move") : LocalizedStringKey("Black to move"))
                        }
                        Spacer(minLength: 4)
                        Text(date, style: .time)
                            .accessibilityLabel(Text("Screenshot"))
                            .accessibilityValue(Text(date, style: .time))
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(ink.opacity(0.75))
        }
        if reply.status == .result {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let description = reply.moveDescription {
                    Text(verbatim: description).font(.title3.bold()).layoutPriority(1)
                }
                if let san = reply.san {
                    Text(verbatim: san).font(.system(.footnote, design: .monospaced))
                        .accessibilityHidden(reply.moveDescription != nil)
                }
            }
            if let data = reply.thumbnail,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 88)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        } else {
            Text(reply.status == .checkmate ? LocalizedStringKey("Checkmate") : LocalizedStringKey("Stalemate")).font(.headline)
        }
    }

    private func message(_ status: WatchAnalysisReply.Status) -> LocalizedStringKey {
        switch status {
        case .setupRequired: "Open Chess Best Move on iPhone and allow full Photos access to read new screenshots."
        case .noFreshScreenshot: "Take a new iPhone screenshot, then tap Analyze within 30 seconds."
        case .needsCorrection: "This position needs confirmation. Open the screenshot in Chess Best Move on iPhone."
        case .noBoard: "No clear chessboard found. Take a screenshot showing the whole board."
        case .noCredits: "No analyses remaining. Open Chess Best Move on iPhone for Pro or more analyses."
        case .busy: "The iPhone app is busy. Leave Chess Best Move on iPhone, then try again."
        case .timedOut: "The iPhone did not finish in time. Open it once, then try again with a new screenshot."
        default: "Could not reach the iPhone app. Check the connection and open Chess Best Move on iPhone once."
        }
    }
}
