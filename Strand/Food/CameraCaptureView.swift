#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign

// MARK: - Camera capture (iOS only — for the AI food photo scan)
//
// `PhotosPicker` (used elsewhere for the avatar/background photo) has no live-capture mode, so a
// still photo of the food actually on the plate needs `UIImagePickerController` with `.camera`
// instead. Falls back to a plain message when no camera is available (simulator, camera-less Mac
// Catalyst), the same pattern `BarcodeScannerScreen` uses for scanner-unsupported devices.

private struct CameraCaptureRepresentable: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data) -> Void
        let onCancel: () -> Void
        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9) else { onCancel(); return }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

/// Full-screen camera sheet: live capture UI, or a plain message on a device without a camera.
struct CameraCaptureScreen: View {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            CameraCaptureRepresentable(
                onCapture: { data in onCapture(data); dismiss() },
                onCancel: { dismiss() }
            )
            .ignoresSafeArea()
        } else {
            VStack(spacing: NoopMetrics.gap) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 32))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("No camera is available on this device.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                NoopButton("Close", kind: .secondary) { dismiss() }
            }
            .padding(NoopMetrics.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
    }
}
#endif
