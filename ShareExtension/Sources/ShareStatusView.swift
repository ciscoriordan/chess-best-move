import SwiftUI

/// What the extension is doing, in the words the screen shows.
///
/// The extension has one job and it takes a moment: put the image where the app can read it
/// and open the app. Everything else is a way that can fail, and each one says what to do
/// instead.
enum SharePhase: Sendable, Hashable {
    /// Reading the image and opening the app.
    case working
    /// The image is in place but the system did not open the app. It is imported anyway when
    /// the app is opened within `ShareInboxNames.handoverWindow`.
    case appDidNotOpen
    /// The shared item is not an image at all.
    case notAnImage
    /// The image could not be read, or could not be handed over.
    case cannotHandOver

    var title: String {
        switch self {
        case .working: "Opening Chess Best Move"
        case .appDidNotOpen: "Ready to analyze"
        case .notAnImage: "That isn't an image"
        case .cannotHandOver: "Couldn't read that image"
        }
    }

    var detail: String {
        switch self {
        case .working: "The app reads the board and finds the best move."
        case .appDidNotOpen: "Open Chess Best Move to see the best move."
        case .notAnImage: "Share a screenshot that shows a chessboard."
        case .cannotHandOver: "Open Chess Best Move and import the screenshot from Photos."
        }
    }

    var isWorking: Bool { self == .working }

    /// What VoiceOver is told when the screen changes to this phase by itself. The extension's
    /// whole job is to report what happened, and the report used to arrive silently: a reader
    /// heard "Opening Chess Best Move" and then nothing, while the screen already said
    /// something else.
    var announcement: String {
        title + ". " + detail
    }
}

/// The phase the screen draws, owned by `ShareViewController`.
@MainActor
@Observable
final class ShareStatus {
    var phase: SharePhase = .working

    init(phase: SharePhase = .working) {
        self.phase = phase
    }
}

/// The extension's only screen: the app's canvas, its type tokens, one line of what is
/// happening, and the same close control the app's own sheets use.
///
/// It scrolls. At the largest text sizes the longest phase needs about 430 pt of text, and in
/// landscape on a phone the sheet has roughly 390 pt of height: without a scroll container the
/// instruction that says what to do next was cut off with no way to reach it. This was the one
/// screen in the app with nothing to scroll.
///
/// When the phase changes it is announced and VoiceOver focus moves to it, because the change
/// is the extension's answer and nothing the reader did causes it.
struct ShareStatusView: View {
    let status: ShareStatus
    let onClose: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s3) {
                    Text(status.phase.title)
                        .typography(.title)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    Text(status.phase.detail)
                        .typography(.body)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.phase.isWorking {
                        ProgressView()
                            .tint(Palette.ink2)
                            .padding(.top, Spacing.s2)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.narrowSideGutter)
                .padding(.top, Spacing.s5)
                .padding(.bottom, Spacing.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.canvas)
            .modalCloseButton(placement: .topBarTrailing) { onClose() }
        }
        .tint(Palette.ink)
        .onChange(of: status.phase) { _, phase in
            AccessibilityNotification.Announcement(phase.announcement).post()
            titleFocused = true
        }
    }
}

#Preview("Working") {
    ShareStatusView(status: ShareStatus(), onClose: {})
}

#Preview("Not an image") {
    ShareStatusView(status: ShareStatus(phase: .notAnImage), onClose: {})
}
