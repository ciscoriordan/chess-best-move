import SwiftUI
import UIKit
import os

/// The share extension's principal class (`NSExtensionPrincipalClass` in its `Info.plist`).
///
/// What it does, in order: take the image out of the share sheet's item, copy it into the app
/// group container, open the app at `chessbestmove://shared-image?id=<uuid>`, and finish the
/// request. What it deliberately does not do is analyze anything. An app extension is given a
/// fraction of the memory an app gets, and this app loads a Core ML piece classifier and a
/// 94 MB neural network and asks the engine for 128 MB of hash; doing that here would be
/// stopped by the system, and the person asked to see the result in the app anyway.
final class ShareViewController: UIViewController {
    private let status = ShareStatus()
    private static let log = Logger(subsystem: "com.motomatic.chessbestmove", category: "share")

    private var hasStarted = false
    /// Set once the image is in the container, so closing by hand finishes the request rather
    /// than reporting it as canceled.
    private var hasHandedOver = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Palette.canvas)
        installContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        start()
    }

    // MARK: The work

    private func start() {
        guard !hasStarted else { return }
        hasStarted = true

        guard let provider = ShareImageIntake.imageProvider(in: extensionContext?.inputItems ?? []) else {
            Self.log.notice("share: the shared item carries no image")
            status.phase = .notAnImage
            return
        }
        guard let inbox = ShareInbox() else {
            // The app group entitlement is missing from this build, or the group was never
            // registered for this bundle id. Nothing can be handed over.
            Self.log.error("share: no app group container for \(ShareInboxNames.appGroupIdentifier, privacy: .public)")
            status.phase = .cannotHandOver
            return
        }

        Task { [weak self] in
            do {
                let id = try await ShareImageIntake.store(provider, into: inbox)
                self?.hasHandedOver = true
                await self?.openApp(withItemID: id)
            } catch {
                Self.log.error("share: could not hand the image over: \(String(describing: error), privacy: .public)")
                self?.status.phase = .cannotHandOver
            }
        }
    }

    /// Opens the app at the hand-over URL and finishes the request. When the system does not
    /// open the app, the image stays in the container: the app imports it when it is next
    /// brought to the front within `ShareInboxNames.handoverWindow`.
    private func openApp(withItemID id: String) async {
        let url = ShareInboxURL.url(forItemID: id)
        guard await open(url) else {
            Self.log.error("share: the system did not open the app")
            status.phase = .appDidNotOpen
            return
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func open(_ url: URL) async -> Bool {
        guard let extensionContext else { return false }
        return await withCheckedContinuation { continuation in
            extensionContext.open(url) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    private func close() {
        if hasHandedOver {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }

    // MARK: The screen

    private func installContent() {
        let host = UIHostingController(rootView: ShareStatusView(status: status, onClose: { [weak self] in self?.close() }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}
