import SwiftUI

struct InvoiceSheet: View {
  let invoice: String
  var body: some View {
    VStack(spacing: 16) {
      Text("Pay this invoice").font(.headline)
        let _ = print("InvoiceSheet incoming invoice:", invoice)
      // Sanitize: trim whitespace and strip any lightning: prefix (with or without //)
        let cleaned = invoice
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: "lightning://", with: "", options: .caseInsensitive)
          .replacingOccurrences(of: "lightning:", with: "", options: .caseInsensitive)

        let _ = print("InvoiceSheet incoming invoice:", invoice)
        let qrPayload = cleaned.isEmpty ? nil : "lightning:\(cleaned)"
      let _ = print("InvoiceSheet qr cleaned:", cleaned)
      let _ = print("InvoiceSheet qr payload:", qrPayload ?? "<nil>")

      if let payload = qrPayload, let img = qrImage(from: payload) {
        Image(nsImage: img) // use UIImage on iOS
          .interpolation(.none)
          .resizable()
          .frame(width: 220, height: 220)
      } else {
        Text("Invoice missing or invalid").foregroundStyle(.red)
      }

      // Show the cleaned raw bolt11 for copy/debug
      ScrollView { Text(cleaned).font(.footnote).textSelection(.enabled) }
      HStack {
        Button("Copy bolt11") {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cleaned, forType: .string)
        }
        Button("Copy lightning:") {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString("lightning:\(cleaned)", forType: .string)
        }
      }
    }
    .padding()
    .frame(minWidth: 320, minHeight: 420)
  }

  private func qrImage(from string: String) -> NSImage? {
    let data = string.data(using: .utf8)
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let outputImage = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let rep = NSCIImageRep(ciImage: outputImage)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }
}
