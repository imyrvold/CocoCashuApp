import SwiftUI
import CoreImage.CIFilterBuiltins

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Renders a string as a QR code — the practical iPhone-to-iPhone hand-off for
/// ecash (the recipient scans it with their wallet's camera). Cashu tokens can
/// be long, so callers should prefer the compact V4 (`cashuB`) format for QR.
struct TokenQRView: View {
    let content: String
    var size: CGFloat = 240

    var body: some View {
        Group {
            if let image = Self.qrImage(from: content) {
                Image(platformImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityLabel("Ecash token QR code")
            } else {
                // Too much data for a QR (very large token) — fall back to text.
                Text("Token too large for a QR code — copy or tap-to-card instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: size)
            }
        }
    }

    static func qrImage(from string: String) -> PlatformImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #elseif os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
        #endif
    }
}
