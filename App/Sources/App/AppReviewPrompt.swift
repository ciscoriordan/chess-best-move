import Foundation
import Observation
import StoreKit
import SwiftUI
import UIKit

/// One foreground opening per process, not one opening per scene activation.
/// A Watch background launch does not count until the phone interface first becomes active.
@MainActor
@Observable
final class AppReviewPrompt {
    enum Key {
        static let foregroundLaunchCount = "appReview.foregroundLaunchCount"
        static let hasRequestedReview = "appReview.hasRequestedReview"
    }

    static let qualifyingLaunchCount = 3
    static let settlingDelay: Duration = .seconds(2)
    static let shared: AppReviewPrompt = {
        // Keep automatic system prompts out of development, unit/UI tests, and simulator
        // screenshot captures. Tests exercise enabled instances with their own preferences.
        #if DEBUG || targetEnvironment(simulator)
        AppReviewPrompt(enabled: false)
        #else
        AppReviewPrompt()
        #endif
    }()

    @ObservationIgnored private let defaults: UserDefaults
    let enabled: Bool
    private(set) var foregroundLaunchCount: Int
    private(set) var hasRequestedReview: Bool
    private var hasCountedThisProcess = false
    private var hasLeftInitialForeground = false
    private var isSceneActive = false

    init(defaults: UserDefaults = .standard, enabled: Bool = true) {
        self.defaults = defaults
        self.enabled = enabled
        foregroundLaunchCount = min(Self.qualifyingLaunchCount,
                                   max(0, defaults.integer(forKey: Key.foregroundLaunchCount)))
        hasRequestedReview = defaults.bool(forKey: Key.hasRequestedReview)
    }

    var isEligible: Bool {
        enabled && isSceneActive && hasCountedThisProcess && !hasLeftInitialForeground
            && foregroundLaunchCount == Self.qualifyingLaunchCount && !hasRequestedReview
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        guard enabled else { return }
        isSceneActive = phase == .active
        switch phase {
        case .active:
            guard !hasCountedThisProcess else { return }
            hasCountedThisProcess = true
            // Saturate at the threshold; this counter is not an analytics event stream.
            foregroundLaunchCount = min(Self.qualifyingLaunchCount, foregroundLaunchCount + 1)
            defaults.set(foregroundLaunchCount, forKey: Key.foregroundLaunchCount)
        case .background:
            // If launch three is interrupted, defer to a later cold launch. Never show an
            // old pending request merely because the user returns from their chess app.
            if hasCountedThisProcess { hasLeftInitialForeground = true }
        case .inactive:
            // Permission dialogs and Control Center do not create another opening.
            break
        @unknown default:
            break
        }
    }

    func requestWhenSettled(
        after delay: Duration = settlingDelay,
        isReady: () -> Bool,
        request: () -> Void
    ) async {
        guard isEligible, !Task.isCancelled else { return }
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled, isEligible, isReady() else { return }
        // StoreKit does not tell us whether it displayed the dialog or received a rating.
        // Persist the attempt first, so dismissal, scene updates, or relaunch cannot repeat it.
        hasRequestedReview = true
        defaults.set(true, forKey: Key.hasRequestedReview)
        request()
    }
}

private struct AppReviewPromptModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var prompt = AppReviewPrompt.shared
    let capture: CaptureHomeModel
    let isWidgetImporting: Bool

    private struct Trigger: Equatable {
        let phase: ScenePhase
        let eligible: Bool
        let canSettle: Bool
        let interactionRevision: Int
        let enginePhase: EnginePhase
    }

    private var captureIsIdle: Bool {
        !capture.isImporting && !capture.showsPhotoPicker && !capture.showsScreenshotPicker
            && capture.importError == nil && !isWidgetImporting
    }

    func body(content: Content) -> some View {
        let trigger = Trigger(phase: scenePhase, eligible: prompt.isEligible,
                              canSettle: app.path.isEmpty && app.sheet == nil && app.editor == nil
                                  && app.store.hasLoadedEntitlements && captureIsIdle,
                              interactionRevision: app.screenshotInteractionRevision,
                              enginePhase: app.engine.phase)
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                prompt.scenePhaseChanged(to: phase)
            }
            .task(id: trigger) {
                guard trigger.phase == .active, trigger.eligible, trigger.canSettle else { return }
                await prompt.requestWhenSettled {
                    UIApplication.shared.applicationState == .active
                        && app.canPresentReviewPrompt && captureIsIdle
                } request: {
                    requestReview()
                }
            }
    }
}

extension View {
    func requestsAppStoreReview(capture: CaptureHomeModel, isWidgetImporting: Bool) -> some View {
        modifier(AppReviewPromptModifier(capture: capture, isWidgetImporting: isWidgetImporting))
    }
}
