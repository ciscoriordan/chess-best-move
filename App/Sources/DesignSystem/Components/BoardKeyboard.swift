import ChessCore
import SwiftUI
import UIKit

/// Driving a board from a hardware keyboard (design.md 12, "Keyboard").
///
/// The app ships for iPad as well as iPhone, and an iPad has a keyboard on it more often than
/// not. A plain view with an `onTapGesture` answers a finger and nothing else, which is what
/// the editor's sixty-four squares and the board on Check position were.
///
/// **A board is one keyboard stop, not sixty-four.** Sixty-four stops would be sixty-four Tab
/// presses to cross one screen, which is not access. The shape chess software settles on, and
/// the one here: an arrow key summons a cursor, the arrow keys move it square by square, Space
/// or Return does what a tap on that square does, and Escape puts it away.
///
/// The sixty-four VoiceOver elements are untouched by any of it. VoiceOver has its own
/// navigation of these boards and reads them square by square; this is a second model beside it
/// rather than on top of it, and the cursor appears only once a key has been pressed, so a
/// touch user never sees one.
enum BoardKeyboard {
    /// Which way an arrow key moves the cursor, **as the board is drawn**: up is toward the top
    /// of the screen whichever color is at the bottom.
    enum Direction: Sendable, Hashable, CaseIterable, Identifiable {
        case up, down, left, right

        var id: Self { self }

        /// The step in display cells (rows down, columns right).
        var step: (rows: Int, columns: Int) {
            switch self {
            case .up: (-1, 0)
            case .down: (1, 0)
            case .left: (0, -1)
            case .right: (0, 1)
            }
        }

        /// The `UIKeyCommand` input string for this arrow key.
        var keyCommandInput: String {
            switch self {
            case .up: UIKeyCommand.inputUpArrow
            case .down: UIKeyCommand.inputDownArrow
            case .left: UIKeyCommand.inputLeftArrow
            case .right: UIKeyCommand.inputRightArrow
            }
        }

        /// What the key command is called in the keyboard shortcut list a long press on the
        /// Command key brings up.
        var commandTitle: String {
            switch self {
            case .up: "Move the board cursor up"
            case .down: "Move the board cursor down"
            case .left: "Move the board cursor left"
            case .right: "Move the board cursor right"
            }
        }
    }

    /// The square the cursor moves to, or `square` itself at the edge of the board.
    ///
    /// The cursor stops at the edge rather than wrapping around to the far side. Wrapping saves
    /// a key press and costs the one thing a cursor has to have, which is that holding a
    /// direction takes you somewhere predictable: with wrapping, one press too many at the top
    /// of the h file puts you at the bottom of it, seven ranks from where you were looking.
    static func move(from square: Square, _ direction: Direction, whiteAtBottom: Bool) -> Square {
        let cell = BoardGeometry.cell(of: square, whiteAtBottom: whiteAtBottom)
        let step = direction.step
        let row = min(max(cell.row + step.rows, 0), 7)
        let column = min(max(cell.column + step.columns, 0), 7)
        return BoardGeometry.square(row: row, column: column, whiteAtBottom: whiteAtBottom) ?? square
    }

    /// The identifier of the DEBUG probe a board carries under `-uiTestProbe`.
    static let probeIdentifier = "board.keyboardProbe"

    /// What the key commands are called in the keyboard shortcut list a long press on the
    /// Command key brings up.
    static let activateCommandTitle = "Use the square the board cursor is on"
    static let dismissCommandTitle = "Put the board cursor away"

    /// Where the cursor starts the first time a board takes keyboard focus.
    ///
    /// In order: the square the screen is already pointing at (the editor's selected square),
    /// then the first square recognition was unsure about, because on these two screens a
    /// marked square is what the user came to fix and the custom actions already offer them by
    /// name; then the bottom left corner of the board as it is drawn, which is a fixed place
    /// rather than a guess.
    static func home(selected: Square?, flagged: Set<Square>, whiteAtBottom: Bool) -> Square {
        if let selected { return selected }
        let first = flagged
            .map { (BoardGeometry.cell(of: $0, whiteAtBottom: whiteAtBottom), $0) }
            .min { ($0.0.row, $0.0.column) < ($1.0.row, $1.0.column) }
        if let first { return first.1 }
        // Row 7, column 0 is always a square; `Square.all[0]` is a1, and is only there so this
        // reads without a forced unwrap.
        return BoardGeometry.square(row: 7, column: 0, whiteAtBottom: whiteAtBottom) ?? Square.all[0]
    }
}

/// Gives the board inside it a keyboard cursor, and makes it one stop for Full Keyboard Access.
///
/// Touch is untouched: this adds key handling and takes no gesture away. So is VoiceOver: the
/// board's own elements still answer it, and the cursor is drawn only after a key press.
struct BoardKeyboardControl<Content: View>: View {
    let whiteAtBottom: Bool
    /// Where the cursor goes when the first key summons it, read then rather than now.
    let home: () -> Square
    /// Space or Return on the cursor's square: the same thing a tap on it does.
    let activate: (Square) -> Void
    /// The cursor to draw. Nil until a key summons it, so a touch user never sees it.
    @Binding var cursor: Square?
    @ViewBuilder var content: () -> Content

    /// Where the cursor was when it was last put away, so the next key resumes.
    @State private var remembered: Square?
    /// Whether a keyboard is attached, as UIKit's focus system reports it. Nothing depends on
    /// it; it is in the DEBUG probe so a test that saw no key can say which of the two reasons
    /// it was.
    @State private var focusSystemRuns = false
    #if DEBUG
    /// How many keys the board has taken, for the DEBUG probe.
    @State private var keysTaken = 0
    /// The last few raw key codes that reached the board, for the DEBUG probe. A key command
    /// reports -1, because a command carries an input string rather than a code.
    @State private var rawKeys: [Int] = []
    /// Whether the board holds first responder, which is what decides whether a key can reach
    /// it at all. In the probe so a test can check the board is listening on a machine whose
    /// simulator delivers no hardware keys (`KeyboardAccessUITests`).
    @State private var holdsKeys = false
    #endif

    var body: some View {
        content()
            #if DEBUG
            .overlay(alignment: .topLeading) { probe }
            #endif
            .background { keys }
            // One stop for Full Keyboard Access, which navigates by focus rather than by the
            // responder chain, so that the board is somewhere Tab can land and Space can
            // activate. `.activate` because the board is not a text field.
            .focusable(true, interactions: .activate)
    }

    /// The board's keys, read from UIKit rather than from SwiftUI's focus system.
    ///
    /// Measured on an iPad simulator, 2026-09-20: SwiftUI's `onKeyPress` never fired on a
    /// focused board, and a hidden `Button` carrying `.keyboardShortcut` never fired either. A
    /// `UIView` that becomes first responder, declares key commands and overrides
    /// `pressesBegan` does, with Full Keyboard Access on and with it off, so an iPad user with
    /// a Magic Keyboard and no accessibility settings can use the board.
    @ViewBuilder
    private var keys: some View {
        BoardKeyCatcher(
            hasCursor: cursor != nil,
            onKey: { key in
                switch key {
                case .move(let direction): step(direction)
                case .activate: press()
                case .dismiss: dismiss()
                }
            },
            onFocusSystem: { focusSystemRuns = $0 },
            onRawKey: { code in
                #if DEBUG
                rawKeys = (rawKeys + [code]).suffix(12)
                #endif
            },
            onHoldsKeys: { held in
                #if DEBUG
                holdsKeys = held
                #endif
            }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func step(_ direction: BoardKeyboard.Direction) {
        let from = remembered ?? home()
        // The first key summons the cursor where it was left rather than moving it, so a
        // keyboard user's first press does not skip a square.
        let to = cursor == nil ? from : BoardKeyboard.move(from: from, direction, whiteAtBottom: whiteAtBottom)
        remembered = to
        cursor = to
        #if DEBUG
        keysTaken += 1
        #endif
    }

    private func press() {
        guard let square = cursor else { return }
        activate(square)
    }

    /// Escape puts the cursor away. Where it was is remembered, so the next arrow key brings it
    /// back to the same square rather than to the corner.
    private func dismiss() {
        cursor = nil
    }

    #if DEBUG
    /// `-uiTestProbe`: an invisible element saying where the board's cursor is and how many keys
    /// it has taken, so a UI test can check what a key press did.
    @ViewBuilder
    private var probe: some View {
        if DebugLaunchOptions.uiTestProbe {
            Text("focusSystem=\(focusSystemRuns ? 1 : 0);holdsKeys=\(holdsKeys ? 1 : 0);keys=\(keysTaken);raw=\(rawKeys.map(String.init).joined(separator: "."));last=\(remembered?.algebraic ?? "");cursor=\(cursor?.algebraic ?? "")")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityIdentifier(BoardKeyboard.probeIdentifier)
        }
    }
    #endif
}

/// The keyboard cursor: a ring on the edge of one square, drawn over everything else on the
/// board (design.md 12, "Keyboard").
///
/// It is drawn the way the best-move arrow is drawn, and for the same reason: the board under it
/// can be the user's own screenshot in any board theme, so no single color holds against it. An
/// opaque white band carries the cursor on a dark square and a dark edge on either side of that
/// band carries it on a light one, and one of the two clears 3:1 on every board theme the app
/// reads and on the app's own diagram (`AccessibilityContrastTests`). It uses the arrow's own
/// two tokens rather than a new one, so the same measurement covers both.
///
/// It is achromatic on purpose. The board already spends color on meaning - cobalt is the
/// answer, the selection outline is the dark cobalt, low confidence is amber, a blocking issue
/// is red - and a cursor is not a statement about the square, it is where the keyboard is
/// pointing. Being white and black it is also separable with any color vision at all.
///
/// The band straddles the square's boundary, half in and half out, so it reads as a ring around
/// the square rather than as a third outline inside it, and it is drawn last so that nothing can
/// cover it. On a square at the edge of the board the ring moves in far enough to stay inside
/// the board frame, which clips anything that reaches past it, so it is always drawn whole.
///
/// It does cover the thin mark outlines on its own square - the selection outline, the dashed
/// low-confidence outline - which are drawn in the outermost two points. What it does not cover
/// is the "?" and "!" badges, which sit further in and are what say what is wrong with a square;
/// and the square the cursor activates is named in words under the board.
struct BoardKeyboardCursorRing: View {
    let square: Square
    let whiteAtBottom: Bool

    /// The width of the opaque white band, in square sides.
    static let band: CGFloat = 0.10
    /// The dark edge on each side of it, in points. The arrow's outer edge is one pixel wide
    /// and is what carries it on a light board; a point is that at every display scale.
    static let edge: CGFloat = LineWidth.control

    /// The centerline of the ring for a square on a board `side` points across: the square's own
    /// edge, moved in where the ring would otherwise be clipped by the edge of the board.
    static func ring(for square: Square, side: CGFloat, whiteAtBottom: Bool) -> CGRect {
        let rect = BoardGeometry.rect(of: square, side: side, whiteAtBottom: whiteAtBottom)
        let reach = band * side / 8 / 2 + edge
        let board = CGRect(x: 0, y: 0, width: side, height: side)
        let outer = rect.insetBy(dx: -reach, dy: -reach).intersection(board)
        return outer.insetBy(dx: reach, dy: reach)
    }

    var body: some View {
        let square = square
        let whiteAtBottom = whiteAtBottom
        Canvas { context, size in
            let side = min(size.width, size.height)
            let band = Self.band * side / 8
            let path = Path(
                roundedRect: Self.ring(for: square, side: side, whiteAtBottom: whiteAtBottom),
                cornerRadius: Radius.r1,
                style: .continuous
            )
            context.stroke(path, with: .color(Palette.arrowEdge), lineWidth: band + 2 * Self.edge)
            context.stroke(path, with: .color(Palette.arrowHalo), lineWidth: band)
        }
        .allowsHitTesting(false)
        // The cursor is where the keyboard is pointing, which VoiceOver has its own answer to.
        .accessibilityHidden(true)
    }
}

/// The keys a board takes from a hardware keyboard.
enum BoardKeyboardKey: Sendable, Hashable {
    case move(BoardKeyboard.Direction)
    /// Space or Return.
    case activate
    /// Escape.
    case dismiss
}

/// A zero-sized view that becomes first responder and reads the board's keys from UIKit.
///
/// It takes the arrow keys whenever a board is on screen, because nothing else on these screens
/// uses them and the first press summons the cursor rather than moving it. It takes Space,
/// Return and Escape **only while the cursor is showing**, so before a keyboard user has asked
/// for a cursor those three still belong to the system - to Full Keyboard Access's activation,
/// and to dismissing a sheet.
private struct BoardKeyCatcher: UIViewRepresentable {
    let hasCursor: Bool
    let onKey: (BoardKeyboardKey) -> Void
    let onFocusSystem: (Bool) -> Void
    /// The DEBUG probe's two feeds. They are declared in every configuration because a #if
    /// cannot split an argument list: guarding them here and not at the call site is what
    /// stopped this file compiling in Release (measured 2026-09-20, the screenshot capture).
    /// The call site's closure bodies are empty outside DEBUG, so nothing is recorded.
    let onRawKey: (Int) -> Void
    let onHoldsKeys: (Bool) -> Void

    func makeUIView(context: Context) -> BoardKeyCatcherView {
        let view = BoardKeyCatcherView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: BoardKeyCatcherView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: BoardKeyCatcherView) {
        view.onKey = onKey
        view.hasCursor = hasCursor
        view.onFocusSystem = onFocusSystem
        view.onRawKey = onRawKey
        view.onHoldsKeys = onHoldsKeys
        // A sheet closing over this board leaves the window with no first responder at all, and
        // SwiftUI re-renders the screen underneath when it does. This is the second of the two
        // ways the board takes the keys back; the first is the notification the departing view
        // posts (`BoardKeyCatcherView.didMoveToWindow`).
        view.takeKeysIfNobodyElseHasThem()
    }
}

/// The first responder that reads the keys. Not private: `BoardKeyCatcher` names the type.
final class BoardKeyCatcherView: UIView {
    var onKey: ((BoardKeyboardKey) -> Void)?
    var onFocusSystem: ((Bool) -> Void)?
    var hasCursor = false
    /// Every raw key code that reaches this view, and whether this view holds first responder.
    /// Both feed the DEBUG probe only, and both are nil in a Release build because the call
    /// site's closure bodies are empty there. They are declared unconditionally because the
    /// callers that assign them cannot be split by a #if (measured 2026-09-20: guarding these
    /// stopped the app compiling in Release, which the screenshot capture caught).
    var onRawKey: ((Int) -> Void)?
    var onHoldsKeys: ((Bool) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    /// Posted by a catcher as it leaves its window, so a board that was underneath it takes the
    /// keys back. See `takeKeysIfNobodyElseHasThem()`.
    private static let keysWereFreed = Notification.Name("BoardKeyCatcherViewKeysWereFreed")

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Three moments when the keys may be going spare: another board has just gone away
        // (a sheet dismissed), this window has just become the key one, and the app has just
        // come back to the foreground. Each one asks rather than takes: the handler does
        // nothing unless the keys are actually free.
        for name in [Self.keysWereFreed, UIWindow.didBecomeKeyNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keysMayBeFree), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            // Going away. Whatever board was underneath this one - Check position under the
            // editor sheet - is still on screen and should answer the keyboard again, and it
            // will not find out any other way: `didMoveToWindow` does not fire a second time
            // on a view that never left its window.
            NotificationCenter.default.post(name: Self.keysWereFreed, object: self)
            return
        }
        // On iPadOS the focus system runs as soon as a keyboard is attached, whether or not
        // Full Keyboard Access is on, so this says "there is a keyboard" and not "the user
        // navigates by focus". It is reported for the DEBUG probe and decides nothing.
        onFocusSystem?(UIFocusSystem.focusSystem(for: self) != nil)
        // Nothing in this app takes text, so holding first responder costs nothing. Measured
        // 2026-09-20 on an iPad simulator: the arrow keys, Space and Return reach this view and
        // move and use the cursor, with Full Keyboard Access on and with it off. Should Full
        // Keyboard Access take first responder away to move focus, that is it doing its job,
        // and from then on the board is reached the way every other control is: as a focus stop
        // with an activation of its own.
        becomeFirstResponder()
    }

    @objc private func keysMayBeFree(_ notification: Notification) {
        guard notification.object as AnyObject? !== self else { return }
        // After the run loop has finished taking the other view apart, or `isFirstResponder`
        // still reports the view that is on its way out.
        DispatchQueue.main.async { [weak self] in self?.takeKeysIfNobodyElseHasThem() }
    }

    /// Takes first responder back, but only when nothing else holds it.
    ///
    /// Measured 2026-09-20 (`BoardKeyboardTests.theBoardUnderADismissedSheetTakesTheKeysBack`):
    /// a second board arriving over this one - the editor sheet over Check position - takes
    /// first responder, and when it goes away UIKit leaves the window with **no** first
    /// responder at all. The board underneath is still on screen, so from then on it answered
    /// no key, and nothing brought it back.
    ///
    /// The guard is what keeps this from being a fight: while a board is presented over
    /// another, the one underneath finds a first responder already there and leaves it alone.
    ///
    /// `isKeyWindow` is deliberately not one of the conditions. The app declares
    /// `UIApplicationSupportsMultipleScenes` false, so there is one scene and one window of the
    /// app's own, and during a sheet's dismissal that window is not reliably key at the moment
    /// this runs. "Nothing else holds the keys, in this window" is the condition that matters.
    func takeKeysIfNobodyElseHasThem() {
        guard let window, !window.isHidden, !isFirstResponder else { return }
        if let scene = window.windowScene, scene.activationState == .background { return }
        guard Self.firstResponder(in: window) == nil else { return }
        becomeFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        #if DEBUG
        reportWhetherItHoldsTheKeys()
        #endif
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gaveItUp = super.resignFirstResponder()
        #if DEBUG
        reportWhetherItHoldsTheKeys()
        #endif
        return gaveItUp
    }

    #if DEBUG
    /// On the next turn of the run loop, not now: this is reached from inside a SwiftUI update
    /// (`updateUIView`), and the value it reports is `@State`.
    private func reportWhetherItHoldsTheKeys() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onHoldsKeys?(self.isFirstResponder)
        }
    }
    #endif

    /// The view in `root` that holds first responder, if any.
    private static func firstResponder(in root: UIView) -> UIResponder? {
        if root.isFirstResponder { return root }
        for subview in root.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    /// The board's keys as key commands.
    ///
    /// `pressesBegan` below is not enough on its own: UIKit matches key commands along the
    /// responder chain **before** it delivers a press, so a command anywhere above this view
    /// wins. Measured 2026-09-20 on an iPad simulator: the arrow keys and Space arrived through
    /// `pressesBegan`, and Return and Escape never did, because something further up the chain
    /// claims them (Escape dismisses a sheet, Return activates a default button). Declaring
    /// them here, on the first responder, is what puts the board first.
    ///
    /// `wantsPriorityOverSystemBehavior` is what makes that true of the system's own behaviors
    /// as well, including Full Keyboard Access's arrow navigation while this view holds first
    /// responder. On a board screen the arrow keys are the board's; Tab is left alone, so Full
    /// Keyboard Access still moves between controls with it.
    override var keyCommands: [UIKeyCommand]? {
        var commands = BoardKeyboard.Direction.allCases.map {
            Self.command(input: $0.keyCommandInput, title: $0.commandTitle, action: #selector(takeKey(_:)))
        }
        // Space, Return and Escape only once the cursor is showing, so before a keyboard user
        // has asked for one they still belong to whatever else would answer them.
        guard hasCursor else { return commands }
        commands.append(Self.command(input: " ", title: BoardKeyboard.activateCommandTitle, action: #selector(takeKey(_:))))
        commands.append(Self.command(input: "\r", title: BoardKeyboard.activateCommandTitle, action: #selector(takeKey(_:))))
        commands.append(Self.command(input: UIKeyCommand.inputEscape, title: BoardKeyboard.dismissCommandTitle, action: #selector(takeKey(_:))))
        return commands
    }

    private static func command(input: String, title: String, action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
        // The name in the shortcut list a long press on the Command key brings up.
        command.discoverabilityTitle = title
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func takeKey(_ command: UIKeyCommand) {
        #if DEBUG
        onRawKey?(-1)
        #endif
        guard let key = Self.key(forInput: command.input ?? "", hasCursor: hasCursor) else { return }
        onKey?(key)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !take($0) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func take(_ press: UIPress) -> Bool {
        #if DEBUG
        if let code = press.key?.keyCode { onRawKey?(code.rawValue) }
        #endif
        guard let key = Self.key(for: press, hasCursor: hasCursor) else { return false }
        onKey?(key)
        return true
    }

    /// The board's key for a press, or nil to let it go on up the responder chain.
    ///
    /// The arrows are taken whenever a board is on screen, because nothing else on these
    /// screens uses them and the first press summons the cursor rather than moving it. Space,
    /// Return and Escape are taken **only while the cursor is showing**.
    static func key(for press: UIPress, hasCursor: Bool) -> BoardKeyboardKey? {
        guard let code = press.key?.keyCode else { return nil }
        switch code {
        case .keyboardUpArrow: return .move(.up)
        case .keyboardDownArrow: return .move(.down)
        case .keyboardLeftArrow: return .move(.left)
        case .keyboardRightArrow: return .move(.right)
        case .keyboardSpacebar, .keyboardReturnOrEnter, .keypadEnter: return hasCursor ? .activate : nil
        case .keyboardEscape: return hasCursor ? .dismiss : nil
        default: return nil
        }
    }

    /// The same, for a key command's input string.
    static func key(forInput input: String, hasCursor: Bool) -> BoardKeyboardKey? {
        switch input {
        case UIKeyCommand.inputUpArrow: return .move(.up)
        case UIKeyCommand.inputDownArrow: return .move(.down)
        case UIKeyCommand.inputLeftArrow: return .move(.left)
        case UIKeyCommand.inputRightArrow: return .move(.right)
        case " ", "\r", "\n": return hasCursor ? .activate : nil
        case UIKeyCommand.inputEscape: return hasCursor ? .dismiss : nil
        default: return nil
        }
    }
}
