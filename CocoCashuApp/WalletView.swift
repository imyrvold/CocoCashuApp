// WalletView.swift
import SwiftUI
import Observation
import CocoCashuUI
import CocoCashuCore

struct WalletView: View {
  @Bindable var wallet: ObservableWallet
    @State private var invoiceItem: InvoiceItem? = nil
    @State private var showWithdraw = false
    @State private var withdrawInvoice = ""
    @State private var withdrawAmount = ""
    @State private var isWithdrawing = false
    @State private var withdrawError: String? = nil
    // Payment tracking state
    @State private var isPolling = false
    @State private var paymentStatus: String? = nil
    
  private let demoMint = URL(string: "https://mint.test")!
    let activeMint = URL(string: "https://cashu.cz")! // or mint.coinos.io, etc.

  var body: some View {
    // Precompute values to help the type-checker
    let mintKey = demoMint.absoluteString
    let currentBalance: Int64 = balance(for: demoMint)
    let sortedMints: [String] = Array(wallet.proofsByMint.keys).sorted()

    return VStack(spacing: 16) {
      Text("Cashu Demo Wallet")
        .font(.title.bold())

        // Current balance for the active mint with manual refresh
        HStack(spacing: 12) {
          Text("Balance: \(balance(for: activeMint)) sats")
            .font(.headline)
          Button {
            Task {
              isPolling = true
              await wallet.refresh(mint: activeMint)
              isPolling = false
            }
          } label: {
            if isPolling {
              ProgressView().controlSize(.small)
            } else {
              Text("Refresh")
            }
          }
          .buttonStyle(.bordered)
        }
        
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
          Button("Withdraw (melt)…") {
            showWithdraw = true
          }
          .sheet(isPresented: $showWithdraw) {
            VStack(alignment: .leading, spacing: 12) {
              Text("Withdraw to Lightning").font(.headline)
              Text("Paste a BOLT11 invoice and enter an amount in sats.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

              Text("Invoice (BOLT11)")
              TextField("lnbc1…", text: $withdrawInvoice)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .textSelection(.enabled)
                .onChange(of: withdrawInvoice) {
                  if let sats = parseSatsFromBOLT11(withdrawInvoice) {
                    withdrawAmount = String(sats)
                  }
                }

              Text("Amount (sats)")
              TextField("2", text: $withdrawAmount)
                .textFieldStyle(.roundedBorder)
                .disabled(true)
#if os(iOS)
                .keyboardType(.numberPad)
#endif

              if isWithdrawing { ProgressView().padding(.vertical, 4) }
                if let err = withdrawError { Text(err).foregroundStyle(.red).font(.footnote); let _ = print(err) }

              HStack {
                Spacer()
                Button("Cancel") { showWithdraw = false }
                Button("Withdraw") {
                  Task {
                    withdrawError = nil
                    guard let amt = parseSatsFromBOLT11(withdrawInvoice) else { withdrawError = "Could not parse amount from invoice"; return }
                    let dest = withdrawInvoice.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !dest.isEmpty else { withdrawError = "Invoice is empty"; return }
                    isWithdrawing = true
                    do {
                      try await wallet.manager.mintService.spend(amount: amt, from: activeMint, to: dest)
                      isWithdrawing = false
                      showWithdraw = false
                      withdrawInvoice = ""; withdrawAmount = ""; withdrawError = nil
                    } catch {
                      isWithdrawing = false
                      withdrawError = String(describing: error)
                    }
                  }
                }
                .buttonStyle(.borderedProminent)
                .disabled(withdrawInvoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }
            }
            .padding()
            .frame(minWidth: 360)
          }
          
        Button("Mint 100 sats") {
          Task {
            // In a real flow you’d create a quote and poll until paid,
            // then call MintService.receiveTokens(for:).
            let proof = Proof(amount: 100, mint: demoMint, secret: Data(), C: "", keysetId: "")
            try? await wallet.manager.proofService.addNew([proof])
          }
        }

        Button("Spend 50 sats") {
          Task {
            try? await wallet.manager.proofService.spend(amount: 50, from: demoMint)
          }
        }
          
          Button("Refresh All") {
            Task {
              isPolling = true
              await wallet.refreshAll()
              isPolling = false
            }
          }
          
          Button("Mint 100 sats (real)") {
              print("WalletView: Mint 100 sats (real)")
            Task {
                let mint = activeMint
                let manager = wallet.manager
                let api = RealMintAPI(baseURL: mint)
                let engine = CocoBlindingEngine { mintURL in
                  try await RealMintAPI(baseURL: mintURL).fetchKeyset()
                }
                let flow = MintCoordinator(manager: manager, api: api, blinding: engine)
                do {
                    let (invoice, qid) = try await flow.topUp(mint: mint, amount: 100)
                    await MainActor.run {
                        self.invoiceItem = InvoiceItem(
                            invoice: invoice.trimmingCharacters(in: .whitespacesAndNewlines),
                            quoteId: qid
                        )
                        self.paymentStatus = "Waiting for payment…"
                    }
                    await MainActor.run { self.isPolling = true }
                    print("WalletView invoice:", invoice)
                    // Start background polling so user can scan QR and we auto-dismiss on success
                    Task {
                        do {
                            try await flow.pollUntilPaid(mint: mint, invoice: invoice, quoteId: qid)
                            paymentStatus = "Paid. Fetching tokens…"
                            try await flow.receiveTokens(mint: mint, invoice: invoice, quoteId: qid, amount: 100)
                            paymentStatus = "Tokens received"
                            isPolling = false
                            invoiceItem = nil
                        } catch {
                            paymentStatus = "Error: \(error)"
                            isPolling = false
                        }
                    }
                } catch {
                    // FIX: Print the error if topUp fails
                    print("❌ Minting failed to get invoice:", error)
                    await MainActor.run {
                        self.paymentStatus = "Error starting mint: \(error.localizedDescription)"
                    }
                }
            }
          }
          .sheet(item: $invoiceItem) { item in
            VStack(spacing: 16) {
              InvoiceSheet(invoice: item.invoice)

              if let status = paymentStatus {
                  let _ = print("WalletView paymentStatus:", status)
                Text(status)
                  .font(.footnote)
                  .foregroundStyle(status.hasPrefix("Error") ? .red : .secondary)
              }

              HStack {
                if isPolling { ProgressView().controlSize(.small) }
                Spacer()
                Button("I’ve paid – Refresh") {
                  let manager = wallet.manager
                    let api = RealMintAPI(baseURL: activeMint)
                    let engine = CocoBlindingEngine { mintURL in
                      try await RealMintAPI(baseURL: mintURL).fetchKeyset()
                    }
                    let flow = MintCoordinator(manager: manager, api: api, blinding: engine)
                    isPolling = true
                  Task {
                    do {
                      try await flow.pollUntilPaid(mint: activeMint, invoice: item.invoice, quoteId: item.quoteId)
                      paymentStatus = "Paid. Fetching tokens…"
                      try await flow.receiveTokens(mint: activeMint, invoice: item.invoice, quoteId: item.quoteId, amount: 100)
                      paymentStatus = "Tokens received"
                      isPolling = false
                      invoiceItem = nil
                    } catch {
                      paymentStatus = "Error: \(error)"
                      isPolling = false
                    }
                  }
                }
              }
              .padding(.horizontal)
            }
            .padding()
            .frame(minWidth: 360)
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


private func parseSatsFromBOLT11(_ bolt11: String) -> Int64? {
  // Expect prefix like lnbc[amount][multiplier]
  guard let lnRange = bolt11.range(of: "lnbc", options: [.caseInsensitive]) else { return nil }
  let suffix = bolt11[lnRange.upperBound...]
  // Read numeric+unit until non-alnum
  var digits = ""
  var unit: Character? = nil
  for ch in suffix {
    if ch.isNumber { digits.append(ch) }
    else if "munp".contains(ch) { unit = ch; break }
    else { break }
  }
  guard let unitChar = unit, let amountVal = Int64(digits), amountVal > 0 else { return nil }
  // Convert BTC unit to sats; return only if integral
  switch unitChar {
  case "m": // 1 mBTC = 100_000 sats
    return amountVal * 100_000
  case "u": // 1 μBTC = 100 sats
    return amountVal * 100
  case "n": // 1 nBTC = 0.1 sat => sats = amount/10 if divisible
    guard amountVal % 10 == 0 else { return nil }
    return amountVal / 10
  case "p": // 1 pBTC = 0.0001 sat => sats = amount/10_000 if divisible
    guard amountVal % 10_000 == 0 else { return nil }
    return amountVal / 10_000
  default:
    return nil
  }
}

private struct InvoiceItem: Identifiable {
  let id = UUID()
  let invoice: String
  let quoteId: String?
}
