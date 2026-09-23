import SwiftUI

// MARK: - Documents

/// A license or notice text bundled with the app.
enum SettingsLicenseDocument: String, CaseIterable, Identifiable, Hashable, Sendable {
    case stockfishLicense
    case stockfishAuthors
    case notoSansSymbols

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stockfishLicense: "GNU General Public License v3"
        case .stockfishAuthors: "Stockfish authors"
        case .notoSansSymbols: "Noto Sans Symbols 2"
        }
    }

    /// The bundled file name (copied flat into the app bundle).
    var resourceName: String {
        switch self {
        case .stockfishLicense: "Stockfish-Copying"
        case .stockfishAuthors: "Stockfish-AUTHORS"
        case .notoSansSymbols: "NotoSansSymbols2-OFL"
        }
    }

    /// Hard-wrapped paragraphs are joined into lines that fit the screen; a list with one entry
    /// per line (the authors) keeps its line breaks.
    var reflowsParagraphs: Bool { self != .stockfishAuthors }

    /// The text, or nil if the file is missing from the bundle.
    func text(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Reflowing

/// Splits a plain-text license into blocks that read well on a phone: hard-wrapped paragraphs
/// are joined into one line each (the words are unchanged), indented or centered lines keep
/// their breaks, an unindented all-caps heading line ("PREAMBLE") is its own block, and
/// separator lines made only of dashes become hairlines.
enum SettingsLicenseText {
    enum Block: Hashable, Sendable {
        case paragraph(String)
        case preformatted(String)
        case rule
    }

    static func blocks(from text: String, reflow: Bool = true) -> [Block] {
        var blocks: [Block] = []
        var lines: [Substring] = []

        func flush() {
            defer { lines.removeAll() }
            guard !lines.isEmpty else { return }
            let keepsBreaks = !reflow || lines.contains { line in
                line.prefix(4).allSatisfy(\.isWhitespace) && line.count >= 4
            }
            if keepsBreaks {
                let body = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                blocks.append(.preformatted(body))
            } else {
                let body = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                blocks.append(.paragraph(body))
            }
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "=" }) {
                flush()
                blocks.append(.rule)
            } else if reflow, isHeading(line) {
                flush()
                blocks.append(.paragraph(trimmed))
            } else {
                lines.append(line)
            }
        }
        flush()
        return blocks
    }

    /// A short, unindented line whose letters are all capitals ("PREAMBLE", "DEFINITIONS").
    private static func isHeading(_ line: Substring) -> Bool {
        guard let first = line.first, !first.isWhitespace, line.count <= 40 else { return false }
        let letters = line.filter(\.isLetter)
        return letters.count >= 4 && letters.allSatisfy(\.isUppercase)
    }
}

// MARK: - Screens

/// A paragraph of notice or credit text in `body` (design.md 4), full width.
private struct LegalParagraph: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .typography(.body)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Licenses (design.md 9.8): the notice for the app as a whole, then every bundled component
/// and its license.
///
/// The app's own notice is what GPLv3 section 5(d) calls an Appropriate Legal Notice: the
/// copyright line, that the app is free software under GPLv3, that it comes with no warranty,
/// where the license text is, and where the source of this exact version is. Stockfish is
/// statically linked into the binary, so this covers the whole app, not only the engine.
struct SettingsLicensesView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A plain SectionLabel, not a GroupedSectionLabel: what follows it is the
                // paragraphs, not a card. Both start at the side gutter, as the card's row titles
                // do, so the whole screen reads down one leading line.
                SectionLabel("Chess Best Move")
                VStack(alignment: .leading, spacing: Spacing.s3) {
                    LegalParagraph(SettingsLegal.appCopyright)
                    LegalParagraph(SettingsLegal.appFreeSoftware)
                    LegalParagraph(SettingsLegal.appNoWarranty)
                    LegalParagraph(SettingsLegal.appSourceNotice)
                }
                .padding(.bottom, Spacing.s4)
                GroupedCard {
                    Button { openURL(SettingsLinks.appSource) } label: {
                        ListRow("Source code of this version", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    .accessibilityHint("Opens in Safari.")
                    GroupedRowSeparator(start: .content)
                    NavigationLink(value: SettingsRoute.document(.stockfishLicense)) {
                        ListRow("GNU General Public License v3", value: "Full text", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                }
                GroupedSectionLabel("Chess engine")
                GroupedCard {
                    NavigationLink(value: SettingsRoute.document(.stockfishLicense)) {
                        ListRow("Stockfish", value: "GPLv3", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    GroupedRowSeparator(start: .content)
                    NavigationLink(value: SettingsRoute.networkCredit) {
                        ListRow("Stockfish neural network", value: "ODbL data", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                }
                GroupedSectionLabel("Typeface")
                GroupedCard {
                    NavigationLink(value: SettingsRoute.document(.notoSansSymbols)) {
                        ListRow(SettingsLicenseDocument.notoSansSymbols.title, value: "OFL 1.1", showsChevron: true)
                            .groupedRow()
                    }
                    .buttonStyle(.listRow)
                }
            }
            .sideGutter()
            .padding(.bottom, Spacing.s6)
        }
        .background(Palette.canvas)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A scrollable license text in the `line` token, with text selection.
struct SettingsLicenseTextView: View {
    let document: SettingsLicenseDocument

    @State private var blocks: [SettingsLicenseText.Block] = []
    @State private var isMissing = false

    /// Stockfish's copyright, license and no-warranty notices above its texts.
    private var notices: [String] {
        switch document {
        case .stockfishLicense:
            ["Stockfish \u{2014} " + SettingsLegal.stockfishCopyright, SettingsLegal.stockfishFreeSoftware, SettingsLegal.stockfishNoWarranty]
        case .stockfishAuthors:
            [SettingsLegal.stockfishCopyright]
        case .notoSansSymbols:
            []
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.s3) {
                Text(document.title)
                    .typography(.title)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Spacing.s4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(notices, id: \.self) { notice in
                    Text(notice)
                        .typography(.body)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isMissing {
                    Text("This text is missing from the app. It is available at \(SettingsLinks.gnuLicenses.absoluteString).")
                        .typography(.body)
                        .foregroundStyle(Palette.danger)
                }
                // Running prose is set in `body`, not in `line`.
                //
                // `line` is SF Mono, chosen for engine notation and never given a maximum
                // size. In a 370 pt column at AccessibilityXXXL that is about twelve
                // monospaced characters to the line, and the GPLv3 is full of words and URLs
                // longer than that, so the text broke in the middle of words throughout. The
                // app has to present this license legibly (GPLv3 section 5(d)), and a
                // proportional face at the same size fits about half again as much.
                //
                // A `preformatted` block keeps the monospaced face: it is a block whose own
                // line breaks carry meaning, such as the Stockfish authors list, and there a
                // fixed advance is what lines the entries up.
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let text):
                        Text(text)
                            .typography(.body)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    case .preformatted(let text):
                        Text(text)
                            .typography(.line)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    case .rule:
                        Hairline()
                    }
                }
            }
            .sideGutter()
            .padding(.bottom, Spacing.s6)
        }
        .background(Palette.canvas)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard blocks.isEmpty else { return }
            let document = document
            let loaded = await Task.detached(priority: .userInitiated) {
                document.text().map { SettingsLicenseText.blocks(from: $0, reflow: document.reflowsParagraphs) }
            }.value
            if let loaded { blocks = loaded } else { isMissing = true }
        }
    }
}

/// The neural network's training data credit.
struct SettingsNetworkCreditView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Stockfish neural network")
                    .typography(.title)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Spacing.s4)
                    .padding(.bottom, Spacing.s3)
                    .accessibilityAddTraits(.isHeader)
                Text(SettingsLegal.networkCredit)
                    .typography(.body)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.s5)
                GroupedCard {
                    Button { openURL(SettingsLinks.leelaTrainingData) } label: {
                        ListRow("Leela Chess Zero training data", systemImage: "arrow.up.right.square", showsChevron: true)
                            .groupedRow()
                    }
                    .buttonStyle(.listRow)
                    GroupedRowSeparator()
                    Button { openURL(SettingsLinks.openDatabaseLicense) } label: {
                        ListRow("Open Database License (ODbL)", systemImage: "arrow.up.right.square", showsChevron: true)
                            .groupedRow()
                    }
                    .buttonStyle(.listRow)
                }
            }
            .sideGutter()
            .padding(.bottom, Spacing.s6)
        }
        .background(Palette.canvas)
        .navigationTitle("Neural network")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Chess engine (design.md 9.8): the engine, its license, the modification notice and the
/// source links.
struct SettingsEngineView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(app.engine.engineVersion)
                    .typography(.title)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Spacing.s4)
                    .padding(.bottom, Spacing.s3)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Spacing.s3) {
                    LegalParagraph(SettingsLegal.engineIntroduction(deviceName: AppDevice.current.name))
                    LegalParagraph(SettingsLegal.stockfishCopyright)
                    LegalParagraph(SettingsLegal.stockfishFreeSoftware)
                    LegalParagraph(SettingsLegal.stockfishNoWarranty)
                }
                GroupedSectionLabel("Source code")
                GroupedCard {
                    linkRow("Source code of Stockfish", url: SettingsLinks.stockfishSource)
                    GroupedRowSeparator(start: .content)
                    linkRow("Source code of the version in this app", url: SettingsLinks.appSource)
                    GroupedRowSeparator(start: .content)
                    NavigationLink(value: SettingsRoute.document(.stockfishLicense)) {
                        ListRow("GNU General Public License v3 (full text)", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    GroupedRowSeparator(start: .content)
                    NavigationLink(value: SettingsRoute.document(.stockfishAuthors)) {
                        ListRow("Authors", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                }
                // Paragraph first, card second, so the label heads the paragraph.
                SectionLabel("Changes in this app")
                LegalParagraph(SettingsLegal.stockfishModification)
                    .padding(.bottom, Spacing.s4)
                GroupedCard {
                    linkRow("The change in the published source", url: SettingsLinks.stockfishPatch)
                }
                SectionLabel("Neural network")
                LegalParagraph(SettingsLegal.networkCredit)
                    .padding(.bottom, Spacing.s4)
                GroupedCard {
                    NavigationLink(value: SettingsRoute.networkCredit) {
                        ListRow("Training data and license", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                }
            }
            .sideGutter()
            .padding(.bottom, Spacing.s6)
        }
        .background(Palette.canvas)
        .navigationTitle("Chess engine")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Button { openURL(url) } label: {
            ListRow(title, showsChevron: true).groupedRow()
        }
        .buttonStyle(.listRow)
        .accessibilityHint("Opens in Safari.")
    }
}
