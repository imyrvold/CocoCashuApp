import SwiftUI
import AVFoundation

#if os(iOS)
struct QRScannerView: UIViewControllerRepresentable {
    @Binding var isPresenting: Bool
    var foundCode: (String) -> Void
    /// Continuous mode, for ANIMATED (multi-part BC-UR) QR codes: called for
    /// every distinct frame; return true to finish (vibrate + dismiss), false to
    /// keep scanning. When nil (default), the scanner is single-shot: the first
    /// code is delivered to `foundCode` and the scanner closes.
    var processFrame: ((String) -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
    
    // MARK: - Coordinator (The Bridge)
    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let parent: QRScannerView
        // The delegate fires once per camera frame; without this the same code
        // would be delivered many times, invoking the caller's handler (e.g.
        // claimToken) repeatedly — a duplicate claim that races the first.
        private var didFind = false

        init(parent: QRScannerView) {
            self.parent = parent
        }

        // Last frame delivered in continuous mode, to skip identical repeats
        // (the camera reports the same on-screen frame many times per second).
        private var lastFrame: String?

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !didFind else { return }
            if let metadataObject = metadataObjects.first {
                guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
                guard let stringValue = readableObject.stringValue else { return }

                if let processFrame = parent.processFrame {
                    // Continuous (animated QR) mode.
                    guard stringValue != lastFrame else { return }
                    lastFrame = stringValue
                    if processFrame(stringValue) {
                        didFind = true
                        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                        parent.isPresenting = false
                    }
                    return
                }

                didFind = true

                // Found a code! Audio feedback
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))

                // Stop scanning and pass back
                parent.foundCode(stringValue)
                parent.isPresenting = false
            }
        }
    }
}

// MARK: - UIViewController (The Camera Engine)
class ScannerViewController: UIViewController {
    var captureSession: AVCaptureSession!
    var previewLayer: AVCaptureVideoPreviewLayer!
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()

        captureSession = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
        let videoInput: AVCaptureDeviceInput

        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch { return }

        if (captureSession.canAddInput(videoInput)) {
            captureSession.addInput(videoInput)
        } else { return }

        let metadataOutput = AVCaptureMetadataOutput()

        if (captureSession.canAddOutput(metadataOutput)) {
            captureSession.addOutput(metadataOutput)

            metadataOutput.setMetadataObjectsDelegate(delegate, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else { return }

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        // Start running on background thread to avoid UI lag
        DispatchQueue.global(qos: .background).async {
            self.captureSession.startRunning()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
             // Handle rotation
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            switch orientation {
                case .landscapeLeft: connection.videoOrientation = .landscapeLeft
                case .landscapeRight: connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                default: connection.videoOrientation = .portrait
            }
        }
        previewLayer?.frame = view.layer.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if (captureSession?.isRunning == true) {
            captureSession.stopRunning()
        }
    }
}
#endif
