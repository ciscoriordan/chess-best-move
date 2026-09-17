import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Home (design.md 9.1): the intro at the top, the import actions anchored at the bottom
/// within thumb reach, stacked by speed: latest screenshot, Photos, Paste, then the
/// one-step Shortcut. The whole screen accepts dropped images.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = CaptureHomeModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var isDropTargeted = false

    /// Row symbols grow with the `body` text next to them (ListRow's 20 pt icon column and
    /// 14 pt chevron at the default size).
    @ScaledMetric(relativeTo: .body) private var rowIconSide: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var chevronSize: CGFloat = 14

    init() {}

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
            ToolbarItem(placement: .topBarTrailing) { CreditsToolbarIndicator() }
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
            Text("Best Move")
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

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            latestScreenshot
            if let error = model.importError {
                Text(error)
                    .typography(.caption)
                    .foregroundStyle(Palette.danger)
                    .padding(.top, Spacing.s2)
            }
            rows
                .padding(.top, Spacing.s4)
        }
    }

    private var latestScreenshot: some View {
        let ticks = model.latest == nil ? 3600.0 : 1.0
        return TimelineView(.periodic(from: .now, by: ticks)) { timeline in
            let now = timeline.date
            let state = CaptureLatestScreenshotButton.make(
                access: model.access,
                latest: model.latest,
                analyzed: model.analyzed,
                now: now
            )
            VStack(alignment: .leading, spacing: Spacing.s2) {
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
                .buttonStyle(PrimaryButtonStyle(minHeight: 64))
                .disabled(!state.isEnabled || model.isImporting)
                .accessibilityIdentifier(CaptureAccessibilityID.homeLatestScreenshot)
                .accessibilityLabel(state.title(now: now))
                .accessibilityValue(spokenDetail(state, now: now))

                if let caption = state.caption(deviceName: AppDevice.current.name) {
                    Text(caption)
                        .typography(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state == .limited {
                    TextLink("Allow full access in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        }
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

    @ViewBuilder
    private func thumbnail(for state: CaptureLatestScreenshotButton) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
        if case .latest = state, let image = model.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.onAccent.opacity(0.4), lineWidth: LineWidth.control))
                .accessibilityIgnoresInvertColors()
        } else {
            // Scales with the text, up to what the 48 pt thumbnail slot holds.
            Image(systemName: Self.symbol(for: state))
                .font(.system(size: min(rowIconSide, 28), weight: .regular))
                .frame(width: 48, height: 48)
                .overlay(shape.strokeBorder(.foreground.opacity(0.4), lineWidth: LineWidth.control))
        }
    }

    static func symbol(for state: CaptureLatestScreenshotButton) -> String {
        switch state {
        case .requestAccess, .limited: "photo.badge.checkmark"
        case .denied, .restricted: "lock"
        case .latest, .noScreenshots: "photo"
        }
    }

    private func spokenDetail(_ state: CaptureLatestScreenshotButton, now: Date) -> String {
        switch state {
        case .latest(let asset, _):
            guard let date = asset.creationDate else { return "" }
            return "Taken " + CaptureRecentScreenshotPolicy.spokenAgeText(since: date, now: now)
        default:
            return state.detail(now: now) ?? ""
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            let photosRow = ListRow("Choose from Photos", systemImage: "photo.on.rectangle", showsChevron: true)
            PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                photosRow
            }
            .buttonStyle(.listRow)
            .disabled(model.isImporting)
            .accessibilityIdentifier(CaptureAccessibilityID.homeChooseFromPhotos)

            Hairline(leadingInset: rowTitleInset)
            pasteRow

            Hairline(leadingInset: rowTitleInset)
            Button {
                app.presentShortcutSetup()
            } label: {
                shortcutRow
            }
            .buttonStyle(.listRow)
            .accessibilityIdentifier(CaptureAccessibilityID.homeShortcutSetup)

            #if DEBUG
            Hairline(leadingInset: rowTitleInset)
            Button {
                if let sample = DebugSample.load() { app.importImage(sample) }
            } label: {
                ListRow("Analyze sample screenshot", systemImage: "ladybug")
            }
            .buttonStyle(.listRow)
            .accessibilityIdentifier(AccessibilityID.homeDebugSample)
            #endif
        }
    }

    /// Where row titles start, and so the hairlines between rows: the icon column plus 16 pt.
    private var rowTitleInset: CGFloat { rowIconSide + Spacing.s4 }

    /// Paste (design.md 9.1), laid out as a ListRow: the clipboard symbol in the icon column
    /// and the system paste control, 44 pt tall and tinted `ink`, at the title column. The
    /// system enables the control only while the pasteboard holds an image.
    private var pasteRow: some View {
        HStack(spacing: Spacing.s4) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: rowIconSide))
                .foregroundStyle(Palette.ink)
                .frame(width: rowIconSide)
                .accessibilityHidden(true)
            CapturePasteControl(isEnabled: !model.isImporting, showsIcon: false, accessibilityIdentifier: CaptureAccessibilityID.homePaste) { providers in
                model.importItemProviders(providers, source: .paste, app: app)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Layout.listRowHeight)
    }

    /// The Shortcut row explains the zero-tap path: Take Screenshot then Find Best Move, run
    /// from the Action button or Back Tap. Setup opens the Shortcut sheet.
    private var shortcutRow: some View {
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
        .frame(minHeight: Layout.listRowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

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
