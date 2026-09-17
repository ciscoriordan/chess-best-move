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
        host.acceptsPaste = isEnabled
        host.isUserInteractionEnabled = isEnabled
        host.control.accessibilityIdentifier = accessibilityIdentifier
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView host: CapturePasteControlHost, context: Context) -> CGSize? {
        let fitting = host.control.intrinsicContentSize
        return CGSize(width: fitting.width, height: max(Self.height, fitting.height))
    }
}

/// Hosts the paste control and is its paste target.
final class CapturePasteControlHost: UIView {
    let control: UIPasteControl
    var onPaste: (([NSItemProvider]) -> Void)?
    var acceptsPaste = true

    /// The configuration is fixed once the control exists.
    init(showsIcon: Bool) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = showsIcon ? .iconAndLabel : .labelOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = Radius.r2
        // Tinted `ink` (design.md 9.1): `ink` fill with a `canvas` label, both dynamic.
        configuration.baseBackgroundColor = UIColor(Palette.ink)
        configuration.baseForegroundColor = UIColor(Palette.canvas)
        control = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        acceptsPaste && itemProviders.contains { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard acceptsPaste else { return }
        onPaste?(itemProviders)
    }
}
