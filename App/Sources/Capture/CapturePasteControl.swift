import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system paste control (`UIPasteControl`) for images, as Home's "Paste" row control.
///
/// SwiftUI's `PasteButton` draws a fixed 34 pt pill: it ignores `controlSize`, `frame` and
/// `font`, so it cannot reach the 44 pt minimum hit target (design.md 5). `UIPasteControl` is
/// the same secure control (pasting through it shows no paste permission alert), and it takes
/// the height it is given. The system enables it only while the pasteboard holds an image.
///
/// The host starts where the control's icon starts, not where the control's own edge starts, so
/// a row can place it in the icon column of the rows around it and have the icons line up at
/// every text size (`CapturePasteControlHost.contentInset(for:)`).
struct CapturePasteControl: UIViewRepresentable {
    /// The control's height: the minimum hit target.
    static let height: CGFloat = Layout.minimumHitTarget

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

    /// The control keeps the width of its own label, less the padding the host hangs outside
    /// itself. It cannot be widened to make the whole row tappable: `UIPasteControl` centers its
    /// label in whatever width it is given and exposes no alignment or content inset to stop that
    /// (measured on iOS 27; `contentHorizontalAlignment` has no effect on it), so a row-wide
    /// control would put "Paste" in the middle of the row.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView host: CapturePasteControlHost, context: Context) -> CGSize? {
        host.intrinsicContentSize
    }
}

/// Hosts the paste control and is its paste target.
///
/// The host's leading edge is the control's *content* edge: the control is laid out one content
/// inset outside the host on the leading side, so the row that places this host puts the
/// control's icon, not the control's own padded edge, in the row's icon column
/// (`contentInset(for:)`).
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

    /// The padding the control keeps between its own leading edge and its content, at the text
    /// size this host is drawn at. The control hangs this far outside the host, on the leading
    /// side, so that the content starts at the host's own leading edge.
    private(set) var contentInset: CGFloat = 0
    private var controlLeading: NSLayoutConstraint?

    init(showsIcon: Bool) {
        self.showsIcon = showsIcon
        control = Self.makeControl(showsIcon: showsIcon)
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
        contentInset = Self.contentInset(for: traitCollection.preferredContentSizeCategory)
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
        // The control's own padding grows with the text, so the host has to be told again where
        // the control's content starts whenever the text size changes.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (host: CapturePasteControlHost, _: UITraitCollection) in
            host.updateContentInset()
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

    /// The control is as wide as it wants to be and starts one content inset outside the host on
    /// the leading side, so the host's leading edge falls on the control's icon (or, in
    /// `.labelOnly`, which no screen uses, on its label). Its width is left to the control rather
    /// than tied to the host's trailing edge: a width that came from the host would make the
    /// icon's position depend on the width the row proposed, and the control centers its content
    /// in any width it is given.
    ///
    /// At the largest text sizes that padding is wider than the gutter the row sits on, so the
    /// control's own edge falls outside the screen: 22 pt of padding against a 16 pt gutter puts
    /// it 6 pt off a 402 pt phone at AccessibilityXXXL. The icon, the label and the activation
    /// point are all well inside, `point(inside:)` keeps the overhanging strip answering taps,
    /// and pasting still works there without a permission alert, which
    /// `CaptureImportUITests.testPasteControlIconStaysInTheIconColumnAtTheLargestTextSize`
    /// checks by pasting through it. What the overhang does cost is the VoiceOver focus ring,
    /// which follows the control's frame and is therefore clipped by those 6 pt on the leading
    /// side. The frame is left as it is rather than reported as the host's bounds
    /// (`accessibilityFrameInContainerSpace`), because the control is the accessibility element
    /// and the button a UI test measures, and moving its frame would hide where it really is.
    private func install(_ control: UIPasteControl) {
        control.target = self
        control.isEnabled = acceptsPaste
        control.accessibilityIdentifier = controlAccessibilityIdentifier
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        let leading = control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -contentInset)
        controlLeading = leading
        NSLayoutConstraint.activate([
            leading,
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

    /// Reads the control's content inset for the current text size and moves the control by it.
    /// `invalidateIntrinsicContentSize` is what tells SwiftUI to ask `sizeThatFits` again, so the
    /// host's width follows the padding that has just been taken out of it.
    ///
    /// Measured on a running app (2026-09-22, `xcrun simctl ui <udid> content_size`, iPhone 18
    /// Pro, iOS 27): with Home open, going from AccessibilityXXXL down to the default size moves
    /// the paste icon from 21.33 pt to 17.33 pt from the screen edge, which is where a launch at
    /// the default size puts it, and coming back up to AccessibilityMedium puts it at 18.67 pt.
    /// Without this the control would keep the offset of the text size it was born at, which in
    /// the first of those works out at 7.33 pt from the edge: 22 pt taken off a 16 pt gutter, plus
    /// the 12 pt of padding and the 1.33 pt of side bearing the icon then has.
    private func updateContentInset() {
        let inset = Self.contentInset(for: traitCollection.preferredContentSizeCategory)
        guard inset != contentInset else { return }
        contentInset = inset
        controlLeading?.constant = -inset
        invalidateIntrinsicContentSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Only on the way in. This also fires when the host leaves a window, where the traits are
        // a detached view's and there is nothing to lay out; the next insertion measures again.
        guard window != nil else { return }
        updateContentInset()
    }

    /// The touch area of the paste control, which reaches outside the host on the leading side.
    /// Without this, the control's own padding, which the host hangs outside itself to line the
    /// icon up, would stop answering taps, and the row would lose a strip of the target it has.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || control.frame.contains(point)
    }

    /// The size the row should give this control: as wide as the control, less the padding that
    /// hangs outside the host, and as tall as the control asks to be.
    ///
    /// The control's label never changes, so the last size it reported is kept: a control that
    /// has just been rebuilt can report nothing until it has laid out, and a zero width there
    /// would collapse the row. What is kept is the control's own size, so a text size that
    /// changes the padding takes effect at once, on the size the control last reported.
    var fittingSize: CGSize {
        let intrinsic = control.intrinsicContentSize
        if intrinsic.width > 0 { lastControlSize = intrinsic }
        return CGSize(width: max(0, lastControlSize.width - contentInset), height: lastControlSize.height)
    }

    /// The same size, as an intrinsic size, so that `invalidateIntrinsicContentSize` has
    /// something to invalidate when the text size changes and the padding taken out of the width
    /// changes with it.
    override var intrinsicContentSize: CGSize {
        let fitting = fittingSize
        return CGSize(width: fitting.width, height: max(CapturePasteControl.height, fitting.height))
    }

    /// Asks again once the control has a size of its own to report.
    ///
    /// The control draws out of process and reports nothing until it has drawn: its real size
    /// arrives about 40 ms after the first layout, and during a text-size change the size it
    /// reports is still the one it came from. A row laid out from that stale size keeps the
    /// height of the text size it had before (measured 2026-09-22 with
    /// `xcrun simctl ui <udid> content_size` on a running app: back at the default size the row
    /// was still 77.33 pt tall, AccessibilityXXXL's height, where it should be 44). Noticing the
    /// new size here and invalidating again is what gets the row its own height back; the size is
    /// stored first, so this settles after one more pass.
    override func layoutSubviews() {
        super.layoutSubviews()
        let intrinsic = control.intrinsicContentSize
        guard intrinsic.width > 0, intrinsic != lastControlSize else { return }
        lastControlSize = intrinsic
        invalidateIntrinsicContentSize()
    }

    private var lastControlSize: CGSize = .zero

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        acceptsPaste && itemProviders.contains { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard acceptsPaste else { return }
        onPaste?(itemProviders)
    }

    // MARK: The control's own content inset

    /// How far `UIPasteControl` keeps its icon and label from its own leading edge at this text
    /// size, measured from a UIKit button rather than guessed.
    ///
    /// The control cannot be measured directly: it draws itself out of process (its only subview
    /// in this process is an empty `_UISlotView`, and it opens a connection to
    /// `com.apple.UIKit.SecureControlService`), so there is no icon and no label in its view tree
    /// to read a frame from, and its header offers no content inset. What it does report is its
    /// size, and up to XXXL that size is a UIKit button's: the control's height matches, to the
    /// third of a point, a `UIButton` built with the same configuration (31.00, 32.00, 33.33,
    /// 34.33, 37.00, 39.33 and 41.67 pt at XS to XXXL, iOS 27). Above XXXL the two part company:
    /// at AccessibilityXXXL the control is 224.33 x 77.33 pt and the button 253.00 x 95.67. So at
    /// the five accessibility sizes the button is a model of the control's padding rather than a
    /// twin of the control, and what corroborates it there is the screenshots below.
    ///
    /// So a stand-in button is built with the same content, which is what makes its height
    /// comparable, and laid out at the wanted text size, and the inset UIKit gives it is the
    /// answer: 12 pt at every text size up to XXXL, then 14, 16, 18, 20 and 22 pt at the five
    /// accessibility sizes. Checked against the control itself in screenshots at all twelve
    /// sizes (2026-09-22, iPhone 18 Pro, iOS 27): the paste icon is painted a little further in
    /// than this, by 1.33 pt at the default size and 5.33 pt at AccessibilityXXXL, and by
    /// something between the two at the sizes in between. That is the symbol's own side bearing,
    /// which grows with the symbol; the row's other icons carry the same kind of bearing (at the
    /// default size `photo.on.rectangle` paints 2 pt outside its column and `bolt` 3 pt inside
    /// it), so the paste icon sits inside the spread its neighbors already have.
    ///
    /// The stand-in has to be inside a window whose traits carry the text size: a button that is
    /// detached, or inside a plain view, keeps the app-wide size whatever its `traitOverrides`
    /// say (measured 2026-09-22). The window is never shown and never becomes key. The answer
    /// depends on nothing but the text size, so it is measured once per size and kept. The
    /// stand-in always carries the icon, whatever `displayMode` the control is in, because what
    /// is being read is the button's own padding rather than anything about its content.
    static func contentInset(for category: UIContentSizeCategory) -> CGFloat {
        // `.unspecified` is "whatever the app is set to", which a trait override cannot say:
        // assigning it to `traitOverrides` clears the override instead of setting one, so the
        // measurement would be taken at whatever size the app happened to be and then kept under
        // this key for the life of the process. A host asks with this only before it has a
        // window, and `didMoveToWindow` asks again with a real size.
        guard category != .unspecified else { return fallbackContentInset }
        if let known = measuredContentInsets[category] { return known }
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Paste"
        configuration.image = UIImage(systemName: "doc.on.clipboard")
        let window = measuringWindow
        window.traitOverrides.preferredContentSizeCategory = category
        let button = UIButton(configuration: configuration)
        window.addSubview(button)
        button.frame = CGRect(origin: .zero, size: button.intrinsicContentSize)
        button.setNeedsLayout()
        button.layoutIfNeeded()
        // The inset the button resolved for these traits, which is where it then put its icon:
        // the laid-out icon's own leading edge agrees with it at all twelve text sizes, to within
        // the rounding of a 3x screen (measured 2026-09-22). The resolved inset is the one used,
        // because it is exact where the laid-out frame carries the rounding; the icon is the
        // answer only if a UIKit stops writing the resolved inset back into the configuration,
        // which would otherwise read as no padding at all.
        let resolved = button.configuration?.contentInsets.leading ?? 0
        let measured = resolved > 0 ? resolved : (button.imageView?.frame.minX ?? 0)
        button.removeFromSuperview()
        // A control with no padding between its edge and its icon is not something UIKit has ever
        // drawn here, so an answer of zero means the measurement failed rather than that the
        // padding went away. Fall back to what this row used before 2026-09-22, which is the
        // padding at the default text size, and do not keep it: a later call can still get a real
        // answer.
        guard measured > 0 else { return fallbackContentInset }
        measuredContentInsets[category] = measured
        return measured
    }

    private static var measuredContentInsets: [UIContentSizeCategory: CGFloat] = [:]

    /// The padding at the default text size, which is what the row subtracted at every size until
    /// 2026-09-22. It is the answer when there is nothing to measure against.
    private static let fallbackContentInset: CGFloat = 12

    /// One window for all of the measurements rather than one for each: a `UIWindow` built with
    /// no scene goes through the deprecated main-screen path, and `contentInset(for:)` is reached
    /// from `init`, which SwiftUI calls inside a layout pass. It is never shown and never becomes
    /// key. Each measurement gets a new button, so no button can answer with the size it was last
    /// laid out at.
    private static let measuringWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
}
