import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins
import CocoCashuCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Displays a token/request as a QR, choosing the right physical form:
/// a single STATIC code when it's small enough to scan reliably (universally
/// readable), or an ANIMATED BC-UR stream above that (readable by BC-UR-capable
/// wallets — cashu.me, Cashu app, Minibits — and the only thing that works when
/// a static code would be too dense for screen-to-camera scanning).
struct TokenQRDisplay: View {
    let content: String
    var size: CGFloat = 240

    /// Above this many characters, a single QR's modules get too small to scan
    /// reliably off a screen; switch to the animated stream.
    static let staticLimit = 650

    var body: some View {
        if content.count <= Self.staticLimit {
            TokenQRView(content: content, size: size)
        } else {
            VStack(spacing: 6) {
                AnimatedURQRView(payload: Data(content.utf8), size: size)
                Text("Animated QR — the receiver holds their camera on it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Cycles BC-UR fountain frames (`ur:bytes/N-M/…`) at ~5 fps. Fountain coding
/// means the receiver can join at any frame — the stream never needs restarting.
struct AnimatedURQRView: View {
    let payload: Data
    var size: CGFloat = 240

    @State private var encoder: UREncoder?
    @State private var currentFrame = ""
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !currentFrame.isEmpty, let image = TokenQRView.qrImage(from: currentFrame) {
                Image(platformImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                ProgressView()
                    .frame(width: size, height: size)
            }
        }
        .accessibilityLabel("Animated ecash QR code")
        .onAppear {
            // QR alphanumeric mode can't encode lowercase; UR strings are
            // case-insensitive by design, so uppercase for a denser-yet-scannable
            // byte mode fallback isn't needed — 150-byte fragments stay ~360 chars.
            let enc = UREncoder(payload: payload, maxFragmentLen: 150)
            encoder = enc
            currentFrame = enc.nextPart()
        }
        .onReceive(timer) { _ in
            guard let encoder else { return }
            currentFrame = encoder.nextPart()
        }
    }
}

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
