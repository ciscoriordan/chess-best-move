import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system paste control (`UIPasteControl`) for images, as Home's "Paste" row control.
///
/// SwiftUI's `PasteButton` draws a fixed 34 pt pill: it ignores `controlSize`, `frame` and
/// `font`, so it cannot reach the 44 pt minimum hit target (design.md 5). `UIPasteControl` is
/// the same secure control (pasting through it shows no paste permission alert), and it takes
/// the height it is given. The system enables it only while the pasteboard holds an image.
struct CapturePasteControl: UIViewRepresentable {
    /// The control's height: the minimum hit target.
    static let height: CGFloat = Layout.minimumHitTarget

    /// The padding the control keeps between its own leading edge and its label, measured at
    /// 12 pt on iOS 27. A row that lines the label up with the titles around it subtracts this,
    /// because the control lays out its label itself and takes no content inset from us.
    static let labelInset: CGFloat = 12

    var isEnabled = true
    var showsIcon = true
    var accessibilityIdentifier: String?
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> CapturePasteControlHost {
        let host = CapturePasteControlHost(showsIcon: showsIcon)
        host.onPaste = onPaste
        return host
    }

    func updateUIView(_ host: CapturePasteControlHost, context: Context) {
        host.onPaste = onPaste
        // Blocking hit testing on the host leaves the control inside it enabled as far as the
        // accessibility tree is concerned, so VoiceOver reported "Paste, button" for a button
        // that could not be activated. `acceptsPaste` disables the control itself, which
        // carries the `.notEnabled` trait.
        host.acceptsPaste = isEnabled
        host.isUserInteractionEnabled = isEnabled
        host.controlAccessibilityIdentifier = accessibilityIdentifier
    }

    /// The control keeps the width of its own label. It cannot be widened to make the whole row
    /// tappable: `UIPasteControl` centers its label in whatever width it is given and exposes no
    /// alignment or content inset to stop that (measured on iOS 27; `contentHorizontalAlignment`
    /// has no effect on it), so a row-wide control would put "Paste" in the middle of the row.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView host: CapturePasteControlHost, context: Context) -> CGSize? {
        let fitting = host.fittingSize
        return CGSize(width: fitting.width, height: max(Self.height, fitting.height))
    }
}

/// Hosts the paste control and is its paste target.
final class CapturePasteControlHost: UIView {
    private(set) var control: UIPasteControl
    private let showsIcon: Bool
    var onPaste: (([NSItemProvider]) -> Void)?
    /// Also the control's own enabled state, so the accessibility tree reports what the user
    /// can actually do. A rebuilt control (see `rebuildControl`) picks this up again.
    var acceptsPaste = true {
        didSet { control.isEnabled = acceptsPaste }
    }

    /// Kept on the host rather than set on the control directly, so a rebuilt control carries
    /// it again without waiting for the next update from SwiftUI.
    var controlAccessibilityIdentifier: String? {
        didSet { control.accessibilityIdentifier = controlAccessibilityIdentifier }
    }

    init(showsIcon: Bool) {
        self.showsIcon = showsIcon
        control = Self.makeControl(showsIcon: showsIcon)
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
        install(control)
        // A UIPasteControl resolves the colors of its configuration once, when it is created,
        // and its configuration cannot be replaced afterwards. Switching between light and dark
        // (or turning Increase Contrast on) while the app runs would leave the control painted
        // for the appearance it was born in, which is very visible now that its fill is the card
        // it sits on. Rebuilding it against the new traits is the only way to repaint it.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (host: CapturePasteControlHost, _: UITraitCollection) in
            host.rebuildControl()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The control as Home's "Paste" row draws it (design.md 9.1): the fill is the `raised`
    /// card the row sits in and the label is `ink`, so an enabled control reads like the other
    /// row titles instead of as a filled pill inside a row.
    ///
    /// The fill has to be the card's color rather than `.clear`: UIPasteControl treats a clear
    /// `baseBackgroundColor` as unset and derives a fill from the foreground color instead,
    /// which paints an `ink` pill with an `ink` label on it. With this fill the control draws
    /// no pill in either state: while the pasteboard holds no image it only dims its own label,
    /// the way a disabled row title looks (measured on iOS 27, light and dark).
    private static func makeControl(showsIcon: Bool) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = showsIcon ? .iconAndLabel : .labelOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = Radius.r2
        configuration.baseBackgroundColor = UIColor(Palette.raised)
        configuration.baseForegroundColor = UIColor(Palette.ink)
        return UIPasteControl(configuration: configuration)
    }

    private func install(_ control: UIPasteControl) {
        control.target = self
        control.isEnabled = acceptsPaste
        control.accessibilityIdentifier = controlAccessibilityIdentifier
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildControl() {
        control.removeFromSuperview()
        var rebuilt: UIPasteControl?
        traitCollection.performAsCurrent { rebuilt = Self.makeControl(showsIcon: showsIcon) }
        guard let rebuilt else { return }
        control = rebuilt
        install(rebuilt)
        invalidateIntrinsicContentSize()
    }

    /// The size the row should give this control. The control's label never changes, so the
    /// last width it reported is kept: a control that has just been rebuilt can report nothing
    /// until it has laid out, and a zero width there would collapse the row.
    var fittingSize: CGSize {
        let intrinsic = control.intrinsicContentSize
        if intrinsic.width > 0 { lastFittingSize = intrinsic }
        return lastFittingSize
    }

    private var lastFittingSize: CGSize = .zero

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        acceptsPaste && itemProviders.contains { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard acceptsPaste else { return }
        onPaste?(itemProviders)
    }
}
