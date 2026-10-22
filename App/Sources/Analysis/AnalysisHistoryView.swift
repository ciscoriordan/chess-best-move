import ChessCore
import SwiftUI

struct AnalysisHistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var confirmsClear = false

    private var visibleEntries: [AnalysisHistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.history.entries.filter { query.isEmpty || $0.moveDescription.localizedCaseInsensitiveContains(query)
            || ($0.moveNotation ?? "").localizedCaseInsensitiveContains(query)
            || $0.fen.localizedCaseInsensitiveContains(query) || ($0.result?.bestMove ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if app.history.entries.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text("No Saved Analyses").typography(.title)
                    Text("Completed analyses appear here. Reopen a saved result without using another analysis.")
                        .typography(.body).foregroundStyle(Palette.ink2)
                }
                .padding(.vertical, Spacing.s4)
                .listRowBackground(Palette.canvas)
            } else {
                ForEach(visibleEntries) { entry in
                    Button { app.openHistory(entry) } label: { row(entry) }
                        .buttonStyle(.plain)
                        .listRowBackground(Palette.canvas)
                        .accessibilityIdentifier("history.entry.\(entry.id)")
                        .swipeActions {
                            Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                                app.history.remove(entry.id)
                            }
                        }
                }
            }
            Section {
                Text("Your last 500 positions and results are saved only on this device. Original screenshots are not saved. Deleting history does not restore spent analyses.")
                    .typography(.caption).foregroundStyle(Palette.ink2)
                if let error = app.history.storageError {
                    Text(error).typography(.callout).foregroundStyle(Palette.danger)
                }
            }
            .listRowBackground(Palette.canvas)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle(String(localized: "History"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search moves or positions"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "Clear History"), systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(app.history.entries.isEmpty && app.history.storageError == nil)
                    .accessibilityIdentifier("history.clear")
            }
        }
        .alert(String(localized: "Clear History?"), isPresented: $confirmsClear) {
            Button(String(localized: "Clear History"), role: .destructive) { app.history.clear() }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text("This removes saved positions and results from this device. It does not restore spent analyses.")
        }
        .accessibilityIdentifier("history.screen")
    }

    private func row(_ entry: AnalysisHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: Spacing.s3) {
            if let position = entry.snapshot?.position {
                DiagramBoard(board: position.board, whiteAtBottom: entry.whiteAtBottom, showsCoordinates: false)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.s1) {
                Text(app.settings.moveDisplayFormat.text(words: entry.moveDescription, notation: entry.moveNotation) ?? entry.moveDescription)
                    .typography(.body).bold().foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.analyzedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .typography(.caption).foregroundStyle(Palette.ink2)
                Text(verbatim: entry.engineVersion).typography(.caption).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Palette.ink2).accessibilityHidden(true)
        }
        .padding(.vertical, Spacing.s2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the saved result without starting a new search.")
    }
}
