/// One automatic request per foreground visit, after the saved preference is available.
/// Wrist-down inactive transitions and repeated activation callbacks are not new visits.
struct WatchOpenAnalysisState {
    enum Phase { case active, inactive, background }
    private var phase: Phase?
    private var pendingOpen = true
    private var hasPreferences = false
    private var enabled = true

    mutating func setPhase(_ phase: Phase) {
        if phase == .background, self.phase != .background { pendingOpen = true }
        self.phase = phase
    }

    mutating func applyPreference(enabled: Bool) {
        self.enabled = enabled
        hasPreferences = true
    }

    mutating func consumeManualIntent() { pendingOpen = false }

    mutating func shouldAnalyze(sessionIsReady: Bool, isAnalyzing: Bool) -> Bool {
        guard phase == .active, hasPreferences, sessionIsReady, pendingOpen else { return false }
        // A manual tap or a previous in-flight request satisfies this visit too.
        pendingOpen = false
        return enabled && !isAnalyzing
    }
}
