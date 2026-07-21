import SwiftUI
import CocoCashuUI
import CocoCashuCore

#if os(iOS)
import UIKit
#endif

/// Create a NUT-18 payment request and show it as a QR (a `creqA…`) so another
/// wallet can pay you. The counterpart scans it, produces a matching token, and
/// hands that token back (its own QR) for you to claim — the card-free,
/// iPhone-to-iPhone "request N sats" flow.
struct RequestPaymentView: View {
    let wallet: ObservableWallet
    @Environment(\.dismiss) private var dismiss

    @State private var amountString = ""
    @State private var creq: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Request Payment").font(.headline)

            if let creq {
                Text("Show this to the payer. When they pay, scan the token they show back (Receive → Scan QR) to claim it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TokenQRView(content: creq, size: 220)

                Button("Copy Request") {
                    #if os(iOS)
                    UIPasteboard.general.setItems(
                        [["public.utf8-plain-text": creq]],
                        options: [.expirationDate: Date().addingTimeInterval(300)]
                    )
                    #endif
                }
                .buttonStyle(.bordered)

                Button("New Request") { self.creq = nil; self.amountString = "" }
            } else {
                Text("Amount to request (sats)").foregroundStyle(.secondary)
                TextField("Amount", text: $amountString)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 150)

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }

                Button("Create Request") { createRequest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(Int64(amountString) == nil)
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 320)
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func createRequest() {
        guard let amount = Int64(amountString), amount > 0 else { return }
        errorMessage = nil

        Task {
            // Name the mints WE hold, so the token the payer creates lands at a
            // mint we can claim from. Fall back to the default mint on a fresh
            // wallet with no balances yet.
            let mints = wallet.mintBalances.map(\.url)
            let requestMints = mints.isEmpty ? [CashuBootstrap.defaultMint.absoluteString] : mints

            let request = PaymentRequest(
                id: String(UUID().uuidString.prefix(8)).lowercased(),
                amount: amount,
                unit: "sat",
                mints: requestMints
            )
            do {
                let encoded = try request.encode()
                await MainActor.run { self.creq = encoded }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }
}
