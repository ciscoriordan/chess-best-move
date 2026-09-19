import SwiftUI

/// The native close control for modal sheets and full-screen covers: `Button(role: .close)`,
/// which the system draws as its standard close control and labels for VoiceOver itself.
/// There is never a "Done" text button to dismiss a modal in this app.
struct CloseButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(role: .close, action: action)
    }
}

/// A toolbar item holding `CloseButton`.
struct CloseToolbarItem: ToolbarContent {
    var placement: ToolbarItemPlacement = .cancellationAction
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: placement) {
            CloseButton(action: action)
        }
    }
}

extension View {
    /// Adds the native close control to the navigation bar. Place the view inside a
    /// `NavigationStack` in the modal. `placement` defaults to the leading
    /// cancellation position; the paywall uses `.topBarTrailing`.
    func modalCloseButton(placement: ToolbarItemPlacement = .cancellationAction, action: @escaping () -> Void) -> some View {
        toolbar { CloseToolbarItem(placement: placement, action: action) }
    }
}

#Preview("Close button") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                Text("Settings")
                    .typography(.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Spacing.s4)
                    .background(Palette.canvas)
                    .modalCloseButton {}
            }
        }
}
