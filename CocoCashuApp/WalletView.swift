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
          
          Button("Mint 100 sats (real)") {
              print("WalletView: Mint 100 sats (real)")
            Task {
              let mint = demoMint
              let manager = wallet.manager
              let api = RealMintAPI(baseURL: URL(string: "https://cashu.cz")!)
              let flow = MintCoordinator(manager: manager, api: api)
              let (invoice, _) = try await flow.topUp(mint: mint, amount: 100)
                print("WalletView invoice:", invoice)
              // TODO: show a sheet with the BOLT11 invoice for the user to pay
              try await flow.pollUntilPaid(mint: mint, invoice: invoice)
              try await flow.receiveTokens(mint: mint, invoice: invoice)
            }
          }
          
          Button("Pay LN invoice") {
            Task {
              let destination = "lnbc1p...YOURINVOICE..."
              let mint = demoMint
              // Choose an amount (parse from invoice ideally)
              try await wallet.manager.mintService.spend(amount: 50, from: mint, to: destination)
              // If your melt returns change proofs, call proofService.addNew(changeProofs)
              // In our demo, melt returns only a preimage; you can follow with markSpent if needed.
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
    
    // 1) Ask mint for invoice
    func startTopUp(_ sats: Int64) {
      Task {
        let mintURL = demoMint
        // create quote: get invoice + optional quoteId stored in QuoteService (if you wire that)
        // or call API directly and store a local Quote:
        let api = (wallet.manager as AnyObject) // just to hint location; you can hold api in manager or expose via method
        // For a quick start, call the API directly if you’ve kept a reference,
        // otherwise add a small MintCoordinator that uses wallet.manager.quoteService + mintService
      }
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
