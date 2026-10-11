import PhotosUI
import SwiftUI

/// The system Photos picker for an App Shortcut invoked without an image. PHPicker does
/// not request library-wide access; only the image the user selects is handed to the app.
struct CaptureShortcutPhotoPicker: UIViewControllerRepresentable {
    let onSelection: (PHPickerResult?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.onSelection = onSelection
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onSelection: (PHPickerResult?) -> Void

        init(onSelection: @escaping (PHPickerResult?) -> Void) {
            self.onSelection = onSelection
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelection(results.first)
        }
    }
}
