/// Copy shared by several screens (design.md section 14).
///
/// The app is presented as a tool for analyzing positions, reviewing games and solving
/// puzzles, never as help during a game being played (owner decision of 2026-09-17). Home
/// and Settings > Help both show the fair-play note.
enum AppCopy {
    /// Home's intro line under the wordmark.
    static let homeIntro = "Analyze any position from a screenshot: a game you are reviewing, a puzzle or a study."

    /// Home's one-line reminder once HOW IT WORKS has collapsed after the first analysis.
    static let homeCollapsedSteps = "Screenshot a position, then tap Use latest screenshot."

    /// The one-line fair-play note, on Home under the steps and in Settings > Help.
    static let fairPlayNote = "Most chess sites do not allow engine help in games you are playing."
}
