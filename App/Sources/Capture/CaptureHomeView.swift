import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Home (design.md 9.1): the intro at the top, the import actions anchored at the bottom
/// within thumb reach, stacked by speed in one grouped card that spans the screen edge to edge:
/// latest screenshot, Photos, Paste, then the one-step Shortcut. The whole screen accepts
/// dropped images.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var model = CaptureHomeModel()
    /// An import failure is a footer four elements below the button that caused it, so it is
    /// announced and focused rather than left to be found.
    @AccessibilityFocusState private var importErrorFocused: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var isDropTargeted = false

    /// Row symbols grow with the `body` text next to them (ListRow's 20 pt icon column and
    /// 14 pt chevron at the default size), and stop where ListRow's do, so the words in the
    /// row keep their width (`Layout.maximumRowIcon`).
    @ScaledMetric(relativeTo: .body) private var scaledRowIconSide: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var scaledChevronSize: CGFloat = 14

    private var rowIconSide: CGFloat { min(scaledRowIconSide, Layout.maximumRowIcon) }
    private var chevronSize: CGFloat { min(scaledChevronSize, Layout.maximumRowChevron) }

    init() {}

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CreditsInlineIndicator()
                    intro
                    Spacer(minLength: Spacing.s6)
                    actions
                }
                .sideGutter()
                .padding(.top, Spacing.s2)
                .padding(.bottom, Spacing.s4)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { SettingsToolbarButton() }
            ToolbarItem(placement: .topBarTrailing) {
                CreditsToolbarIndicator(dynamicTypeSize: dynamicTypeSize)
            }
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.stateShort), value: isDropTargeted)
        .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
            model.importItemProviders(providers, source: .dragAndDrop, app: app)
        }
        .onChange(of: model.importError) { _, error in
            guard let error else { return }
            AccessibilityNotification.Announcement(error).post()
            importErrorFocused = true
        }
        .photosPicker(
            isPresented: $model.showsScreenshotPicker,
            selection: $pickerItem,
            matching: .screenshots,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        )
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            #if DEBUG
            DebugTimeline.shared.begin("photosPickerSelection")
            #endif
            pickerItem = nil
            Task { await model.importPickerItem(item, app: app) }
        }
        .task {
            #if DEBUG
            await CaptureDebugLaunch.run(app: app, model: model)
            #endif
            await model.refresh()
        }
        .task {
            // A new stream per appearance: pushing a flow screen cancels this task, which
            // finishes the stream it was iterating.
            for await _ in model.observer.changes() {
                await model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh() }
            }
        }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            // The app's name, the same string as CFBundleDisplayName and the share sheet, so
            // every place the user reads the name agrees. It is longer than the store name's
            // brand alone and wraps to two lines on a narrow phone at large text sizes, which
            // is why nothing below it assumes a one-line height.
            Text("Chess Best Move")
                .typography(.display)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(AppCopy.homeIntro)
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if app.settings.hasCompletedAnalysis {
                Text(AppCopy.homeCollapsedSteps)
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.s1)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("How it works")
                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        ForEach(Array(Self.steps(for: .current).enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.s3) {
                                Text("\(index + 1)")
                                    .typography(.data)
                                    .foregroundStyle(Palette.ink2)
                                    .frame(minWidth: 12, alignment: .leading)
                                Text(step)
                                    .typography(.body)
                                    .foregroundStyle(Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            fairPlayNote
        }
    }

    /// The fair-play note (owner decision 2026-09-17), one `caption` line under the steps or
    /// under the collapsed line, always visible.
    private var fairPlayNote: some View {
        Text(AppCopy.fairPlayNote)
            .typography(.caption)
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Spacing.s1)
            .accessibilityIdentifier(CaptureAccessibilityID.homeFairPlayNote)
    }

    /// HOW IT WORKS. The first step names the screenshot buttons of this device.
    static func steps(for device: AppDevice) -> [String] {
        [
            device.screenshotStep,
            "Come back here.",
            "Tap Use latest screenshot.",
        ]
    }

    // MARK: Actions

    /// The four import actions as one grouped list: a `GroupedCard` holding the primary
    /// "Use latest screenshot" row, Photos, Paste and the Shortcut, with the state captions and
    /// any import error as the group's footer under the card. The card reaches out through the
    /// screen's side gutter to both screen edges (owner decision of 2026-09-22, design.md 9.1),
    /// and its rows, like the footer, start their content on the gutter line of the intro above.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupedCard {
                latestScreenshotRow
                photosRow
                GroupedRowSeparator()
                pasteRow
                GroupedRowSeparator()
                shortcutSetupRow
                #if DEBUG
                GroupedRowSeparator()
                debugSampleRow
                #endif
            }
            footer
        }
    }

    /// The primary row. Its title and second line follow the clock (relative ages such as
    /// "Taken 12 seconds ago"), so it redraws on a timeline of its own rather than redrawing
    /// the whole card every second.
    private var latestScreenshotRow: some View {
        let ticks = model.latest == nil ? 3600.0 : 1.0
        return TimelineView(.periodic(from: .now, by: ticks)) { timeline in
            let now = timeline.date
            let state = CaptureLatestScreenshotButton.make(
                access: model.access,
                latest: model.latest,
                analyzed: model.analyzed,
                now: now
            )
            Button {
                #if DEBUG
                DebugTimeline.shared.begin("latestScreenshotTap")
                #endif
                Task {
                    await model.useLatestScreenshot(app: app) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } label: {
                latestLabel(state, now: now)
            }
            .buttonStyle(GroupedPrimaryRowButtonStyle(minHeight: 64))
            .disabled(!state.isEnabled || model.isImporting)
            .accessibilityIdentifier(CaptureAccessibilityID.homeLatestScreenshot)
            .accessibilityLabel(state.title(now: now))
            .accessibilityValue(spokenDetail(state, now: now))
            // The steps above name a fixed string ("Tap Use latest screenshot") while the
            // title changes to "Analyze new screenshot" for a fresh screenshot, which is
            // exactly the state a first-time reader following the steps is in. Voice Control
            // matches either name.
            .accessibilityInputLabels([state.title(now: now), "Use latest screenshot"])
        }
    }

    /// The footer under the card, the way a grouped list explains a section: the import
    /// error first, then the caption for the current photo-access state, then the Settings link
    /// that limited access offers. It is absent when there is nothing to say.
    @ViewBuilder
    private var footer: some View {
        let state = photoAccessState
        let caption = state.caption(deviceName: AppDevice.current.name)
        if model.importError != nil || caption != nil || state == .limited {
            GroupedFooter {
                if let error = model.importError {
                    Text(error)
                        .foregroundStyle(Palette.danger)
                        .accessibilityFocused($importErrorFocused)
                }
                if let caption {
                    Text(caption)
                }
                if state == .limited {
                    TextLink("Allow full access in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        }
    }

    /// The button state as far as the footer needs it. The caption and the limited-access link
    /// depend only on photo access, never on the clock, so the footer does not need the primary
    /// row's timeline date (only the promoted title inside the row does).
    private var photoAccessState: CaptureLatestScreenshotButton {
        CaptureLatestScreenshotButton.make(
            access: model.access,
            latest: model.latest,
            analyzed: model.analyzed,
            now: .now
        )
    }

    private func latestLabel(_ state: CaptureLatestScreenshotButton, now: Date) -> some View {
        HStack(spacing: Spacing.s3) {
            thumbnail(for: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title(now: now))
                    .typography(.button)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = state.detail(now: now) {
                    Text(detail)
                        .typography(.caption)
                        .opacity(0.85)
                }
            }
            Spacer(minLength: 0)
            if model.isImporting {
                ProgressView()
                    .tint(Palette.onAccent)
            }
        }
        .padding(.vertical, Spacing.s2)
    }

    /// The tile at the head of the primary row.
    ///
    /// It grows with the text like the icon column of the rows under it, and stops where that
    /// column stops (`Layout.maximumRowIcon` plus the tile's own padding), so the card's icon
    /// column stays a straight vertical line at every text size. It used to be frozen at 48 pt
    /// while the rows below it grew past 60.
    private var thumbnailSide: CGFloat { max(48, rowIconSide + 2 * Spacing.s2) }

    @ViewBuilder
    private func thumbnail(for state: CaptureLatestScreenshotButton) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
        let side = thumbnailSide
        if case .latest = state, let image = model.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.onAccent.opacity(0.4), lineWidth: LineWidth.control))
                .accessibilityIgnoresInvertColors()
        } else {
            Image(systemName: Self.symbol(for: state))
                .font(.system(size: side * 0.58, weight: .regular))
                .frame(width: side, height: side)
                .overlay(shape.strokeBorder(.foreground.opacity(0.4), lineWidth: LineWidth.control))
                .accessibilityHidden(true)
        }
    }

    static func symbol(for state: CaptureLatestScreenshotButton) -> String {
        switch state {
        case .requestAccess, .limited: "photo.badge.checkmark"
        case .denied, .restricted: "lock"
        case .latest, .noScreenshots: "photo"
        }
    }

    /// What VoiceOver reads as the row's value.
    ///
    /// While an import runs it says so, because the row is disabled for the duration and the
    /// spinner inside it is swallowed by the row's own label. When photo access is off or
    /// restricted the reason comes with it, rather than being left in the card's footer four
    /// elements further down: without that, a reader taps the main button of the first screen,
    /// hears nothing, and the button goes dim and comes back.
    private func spokenDetail(_ state: CaptureLatestScreenshotButton, now: Date) -> String {
        if model.isImporting { return "Importing" }
        var parts: [String] = []
        switch state {
        case .latest(let asset, _):
            if let date = asset.creationDate {
                parts.append("Taken " + CaptureRecentScreenshotPolicy.spokenAgeText(since: date, now: now))
            }
        default:
            if let detail = state.detail(now: now) { parts.append(detail) }
        }
        if let caption = state.caption(deviceName: AppDevice.current.name) { parts.append(caption) }
        return parts.joined(separator: ". ")
    }

    private var photosRow: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
            ListRow("Choose from Photos", systemImage: "photo.on.rectangle", showsChevron: true)
                .groupedRow()
        }
        .buttonStyle(.listRow)
        .disabled(model.isImporting)
        .accessibilityIdentifier(CaptureAccessibilityID.homeChooseFromPhotos)
    }

    /// Paste (design.md 9.1), laid out as a row of the card: the system paste control alone,
    /// 44 pt tall, drawing its own icon and its own label and filled with the card's own color so
    /// that it reads like the other row titles. There is no separate symbol beside it, because a
    /// symbol outside the control answered no taps. The system enables the control only while the
    /// pasteboard holds an image, and dims it otherwise.
    ///
    /// The row places the control like any other row's icon, at the row's leading edge, because
    /// the control's host starts at the control's icon rather than at the control's own padded
    /// edge (`CapturePasteControlHost.contentInset(for:)`). Until 2026-09-22 the row subtracted a
    /// hard-coded 12 pt instead, which was the padding at the default text size only, so the icon
    /// drifted right of the icons above and below it as the text grew. The control sets its own
    /// gap between its icon and its label, so the label does not land on the title column of the
    /// rows around it; only the icon column is shared (design.md 9.1).
    private var pasteRow: some View {
        HStack(spacing: Spacing.s4) {
            CapturePasteControl(isEnabled: !model.isImporting, showsIcon: true, accessibilityIdentifier: CaptureAccessibilityID.homePaste) { providers in
                model.importItemProviders(providers, source: .paste, app: app)
            }
            Spacer(minLength: 0)
        }
        .groupedRow()
    }

    /// The Shortcut row explains the zero-tap path: Take Screenshot then Find Best Move, run
    /// from the Action button or Back Tap. Setup opens the Shortcut sheet.
    private var shortcutSetupRow: some View {
        Button {
            app.presentShortcutSetup()
        } label: {
            HStack(spacing: Spacing.s4) {
                Image(systemName: "bolt")
                    .font(.system(size: rowIconSide))
                    .foregroundStyle(Palette.ink)
                    .frame(width: rowIconSide)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up the one-step Shortcut")
                        .typography(.body)
                        .foregroundStyle(Palette.ink)
                    Text("Take Screenshot, then Find Best Move, from the Action button or Back Tap.")
                        .typography(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Spacing.s2)
            .groupedRow()
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.listRow)
        .accessibilityIdentifier(CaptureAccessibilityID.homeShortcutSetup)
    }

    #if DEBUG
    private var debugSampleRow: some View {
        Button {
            if let sample = DebugSample.load() { app.importImage(sample) }
        } label: {
            ListRow("Analyze sample screenshot", systemImage: "ladybug")
                .groupedRow()
        }
        .buttonStyle(.listRow)
        .accessibilityIdentifier(AccessibilityID.homeDebugSample)
    }
    #endif

    // MARK: Drag and drop

    private var dropOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.r3, style: .continuous)
        return shape
            .fill(Palette.canvas)
            .overlay(shape.strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .overlay(alignment: .topLeading) {
                Text("Drop to analyze")
                    .typography(.title)
                    .foregroundStyle(Palette.ink)
                    .padding(Spacing.s4)
            }
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
