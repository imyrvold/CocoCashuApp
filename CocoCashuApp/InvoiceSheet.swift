import SwiftUI

struct InvoiceSheet: View {
  let invoice: String
  var body: some View {
    VStack(spacing: 16) {
      Text("Pay this invoice").font(.headline)
      if let img = qrImage(from: "lightning:\(invoice)") {
        Image(nsImage: img) // use UIImage on iOS
          .interpolation(.none)
          .resizable()
          .frame(width: 220, height: 220)
      }
      ScrollView { Text(invoice).font(.footnote).textSelection(.enabled) }
      Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invoice, forType: .string) }
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
