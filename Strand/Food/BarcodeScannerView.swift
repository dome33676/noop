#if os(iOS)
import SwiftUI
import VisionKit
import StrandDesign

// MARK: - Barcode scanner (iOS only — VisionKit's live scanner has no macOS counterpart)
//
// Wraps `DataScannerViewController` (iOS 16+) restricted to common retail-barcode symbologies, so
// the Food tab can scan a product the way Yazio/similar apps do. Only ever presented from behind the
// Open Food Facts opt-in toggle (§1.1e) — the camera feed never leaves the device; only the
// recognized barcode string is handed to the caller, which sends it on to OFF.

@available(iOS 16.0, *)
private struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .code39, .qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        /// Guards against the delegate firing again with a second item before the sheet has dismissed.
        private var reported = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !reported else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    reported = true
                    onScan(payload)
                    return
                }
            }
        }
    }
}

/// Full-screen scanner sheet: live camera view + a Cancel button, falling back to a plain message on
/// a device/simulator without scanner support instead of presenting a dead camera view.
struct BarcodeScannerScreen: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            if #available(iOS 16.0, *), DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                BarcodeScannerRepresentable { code in
                    onScan(code)
                    dismiss()
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: NoopMetrics.gap) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 32))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Barcode scanning isn't available on this device.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(NoopMetrics.space6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
            }
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .padding()
            }
        }
    }
}
#endif
