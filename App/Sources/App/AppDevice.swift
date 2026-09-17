import Foundation
import UIKit

/// The kind of device the app runs on, for copy that names the device or its buttons. The app
/// is universal (`TARGETED_DEVICE_FAMILY` 1,2), so "your iPhone" and the iPhone screenshot
/// buttons are wrong on an iPad and on an iPhone with a Home button.
enum AppDevice: Sendable, Hashable {
    case iPhone(hasHomeButton: Bool)
    case iPad(hasHomeButton: Bool)
    /// An iPhone or iPad app running on a Mac with Apple silicon.
    case mac

    /// The device the app runs on.
    @MainActor static var current: AppDevice {
        let environment = ProcessInfo.processInfo.environment
        return make(
            modelIdentifier: environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModelIdentifier,
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac
        )
    }

    /// Classifies a device from its model identifier ("iPhone14,6") and interface idiom.
    static func make(modelIdentifier: String, isPad: Bool, isiOSAppOnMac: Bool) -> AppDevice {
        if isiOSAppOnMac { return .mac }
        if isPad { return .iPad(hasHomeButton: homeButtonIPadPrefixes.contains { modelIdentifier.hasPrefix($0) }) }
        return .iPhone(hasHomeButton: homeButtonIPhones.contains(modelIdentifier))
    }

    /// The iPhones with a Home button that run iOS 18 or later: iPhone SE (2nd and 3rd
    /// generation). Every later iPhone has Face ID, so the list is complete.
    static let homeButtonIPhones: Set<String> = ["iPhone12,8", "iPhone14,6"]

    /// The iPads with a Home button that run iPadOS 18 or later: iPad7 (iPad 7th generation,
    /// iPad7,11 and iPad7,12; the older iPad7 models stop at iPadOS 17 and never run the app),
    /// iPad11 (iPad mini 5th generation, iPad Air 3rd generation, iPad 8th generation) and
    /// iPad12 (iPad 9th generation). Every later iPad has no Home button, so the list is
    /// complete.
    static let homeButtonIPadPrefixes = ["iPad7,", "iPad11,", "iPad12,"]

    /// "iPhone", "iPad" or "Mac".
    var name: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .mac: "Mac"
        }
    }

    /// Home's first HOW IT WORKS step (design.md 9.1).
    var screenshotStep: String {
        switch self {
        case .iPhone(hasHomeButton: false): "Take a screenshot of the position: press the side button and volume up together."
        case .iPhone(hasHomeButton: true): "Take a screenshot of the position: press the side button and the Home button together."
        case .iPad(hasHomeButton: false): "Take a screenshot of the position: press the top button and a volume button together."
        case .iPad(hasHomeButton: true): "Take a screenshot of the position: press the top button and the Home button together."
        case .mac: "Take a screenshot of the position."
        }
    }

    /// The button steps of Settings > How to take a screenshot. Both button combinations of the
    /// device family are listed, the one for this device first.
    var screenshotButtonSteps: [String] {
        let withoutHome: String
        let withHome: String
        switch self {
        case .iPhone:
            withoutHome = "With the position on screen, press the side button and the volume up button at the same time."
            withHome = "On an iPhone with a Home button, press the side button and the Home button at the same time."
        case .iPad:
            withoutHome = "With the position on screen, press the top button and either volume button at the same time."
            withHome = "On an iPad with a Home button, press the top button and the Home button at the same time."
        case .mac:
            return ["With the position on screen, take a screenshot."]
        }
        return [withoutHome, withHome]
    }

    private static var hardwareModelIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
