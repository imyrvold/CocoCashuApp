// WalletView.swift
import SwiftUI
import Observation
import CocoCashuUI
import CocoCashuCore

struct WalletView: View {
  @Bindable var wallet: ObservableWallet

  private let demoMint = URL(string: "https://mint.test")!

  var body: some View {
    // Precompute values to help the type-checker
    let mintKey = demoMint.absoluteString
    let currentBalance: Int64 = balance(for: demoMint)
    let sortedMints: [String] = Array(wallet.proofsByMint.keys).sorted()

    return VStack(spacing: 16) {
      Text("Cashu Demo Wallet")
        .font(.title.bold())

      // Current balance for the demo mint
      Text("Balance: \(currentBalance) sats")
        .font(.headline)

      // Proofs list (grouped by mint)
      List {
        ForEach(sortedMints, id: \.self) { mintStr in
          Section(mintStr) {
            let proofs: [Proof] = wallet.proofsByMint[mintStr] ?? []
            ForEach(proofs, id: \.id) { p in
              ProofRow(proof: p)
            }
          }
        }
      }
      .frame(minHeight: 240)

      HStack {
        Button("Mint 100 sats") {
          Task {
            // In a real flow you’d create a quote and poll until paid,
            // then call MintService.receiveTokens(for:).
            let proof = Proof(amount: 100, mint: demoMint, secret: Data())
            try? await wallet.manager.proofService.addNew([proof])
          }
        }

        Button("Spend 50 sats") {
          Task {
            try? await wallet.manager.proofService.spend(amount: 50, from: demoMint)
          }
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
  }

  private func balance(for mint: URL) -> Int64 {
    let proofs = wallet.proofsByMint[mint.absoluteString] ?? []
    return proofs.filter { $0.state == .unspent }.map(\.amount).reduce(0, +)
  }
}

private struct ProofRow: View {
  let proof: Proof

  var body: some View {
    HStack {
      Text("\(proof.amount) sats")
      Spacer()
      Text(proof.state.rawValue)
        .foregroundStyle(proof.state == .unspent ? Color.secondary : Color.orange)
    }
  }
}
