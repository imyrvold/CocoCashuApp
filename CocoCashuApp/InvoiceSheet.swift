import SwiftUI
import CoreImage.CIFilterBuiltins

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct InvoiceSheet: View {
    let invoice: String
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Pay this invoice")
                .font(.headline)
            
            // Sanitize logic
            let cleaned = invoice
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "lightning://", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "lightning:", with: "", options: .caseInsensitive)
            
            let qrPayload = cleaned.isEmpty ? nil : "lightning:\(cleaned)"
            
            if let payload = qrPayload, let img = generateQR(from: payload) {
                // SwiftUI Image wrapper that handles platform differences
                Image(platformImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
            } else {
                Text("Invoice missing or invalid")
                    .foregroundStyle(.red)
            }
            
            // Scrollable text for the invoice string
            ScrollView {
                Text(cleaned)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            .frame(maxHeight: 100)
            
            // Copy Buttons
            HStack {
                Button("Copy bolt11") {
                    copyToClipboard(cleaned)
                }
                .buttonStyle(.bordered)
                
                Button("Copy lightning:") {
                    copyToClipboard("lightning:\(cleaned)")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        // Limit frame size only on macOS to look like a dialog
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 420)
        #endif
    }
    
    // MARK: - Cross-Platform Helpers
    
    // 1. Unified Copy Helper
    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
    
    // 2. Unified Image Generator
    // Returns explicit platform types to avoid ambiguity
    #if os(iOS)
    private func generateQR(from string: String) -> UIImage? {
        let data = string.data(using: .utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage else { return nil }
        // Scale up the CIImage
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        
        // Convert to UIImage
        let context = CIContext()
        if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
    #elseif os(macOS)
    private func generateQR(from string: String) -> NSImage? {
        let data = string.data(using: .utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        
        let rep = NSCIImageRep(ciImage: outputImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
    #endif
}

// 3. SwiftUI Image Extension for Cross-Platform Compatibility
extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}

// 4. Type Alias Helper
#if os(iOS)
typealias PlatformImage = UIImage
#elseif os(macOS)
typealias PlatformImage = NSImage
#endif
