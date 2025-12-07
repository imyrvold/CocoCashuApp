// WalletView.swift
import SwiftUI
import Observation
import CocoCashuUI
import CocoCashuCore

struct WalletView: View {
  @Bindable var wallet: ObservableWallet
    
    // UI State
    @State private var invoiceItem: InvoiceItem? = nil
    @State private var showWithdraw = false
    @State private var withdrawInvoice = ""
    @State private var withdrawAmount = ""
    @State private var isWithdrawing = false
    @State private var withdrawError: String? = nil
    
    // Minting State
    @State private var showMintSheet = false
    @State private var mintAmountString = "100"
    @State private var isRequestingQuote = false
    @State private var mintError: String? = nil

    // Payment tracking state
    @State private var isPolling = false
    @State private var paymentStatus: String? = nil
    
  private let demoMint = URL(string: "https://mint.test")!
    let activeMint = URL(string: "https://cashu.cz")!

  var body: some View {
    // Precompute values
    let sortedMints: [String] = Array(wallet.proofsByMint.keys).sorted()

    return VStack(spacing: 16) {
      Text("Cashu Wallet")
        .font(.title.bold())

        // Current balance for the active mint
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
              Image(systemName: "arrow.clockwise")
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

      HStack(spacing: 20) {
          // MARK: - Mint Button
          Button("Mint…") {
              showMintSheet = true
          }
          .sheet(isPresented: $showMintSheet) {
              mintInputSheet
          }
          
          // MARK: - Withdraw Button
          Button("Withdraw…") {
            showWithdraw = true
          }
          .sheet(isPresented: $showWithdraw) {
              withdrawSheet
          }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
        
        // This sheet displays the QR code once the quote is ready
        .sheet(item: $invoiceItem) { item in
            paymentSheet(for: item)
        }
    }
    .padding()
  }

  // MARK: - Helper Views
    
  private var mintInputSheet: some View {
      VStack(spacing: 20) {
          Text("Mint Tokens").font(.headline)
          Text("Enter the amount you want to receive.")
              .foregroundStyle(.secondary)
          
          TextField("Amount", text: $mintAmountString)
              #if os(iOS)
              .keyboardType(.numberPad)
              #endif
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 150)
          
          if let err = mintError {
              Text(err).foregroundStyle(.red).font(.caption)
          }
          
          if isRequestingQuote {
              ProgressView("Requesting Invoice…")
          } else {
              HStack {
                  Button("Cancel") { showMintSheet = false }
                      .buttonStyle(.bordered)
                  Button("Get Invoice") {
                      startMintingProcess()
                  }
                  .buttonStyle(.borderedProminent)
                  .disabled(Int64(mintAmountString) == nil)
              }
          }
      }
      .padding()
      .frame(minWidth: 300, minHeight: 200)
      .presentationDetents([.height(250)])
  }
    
  private var withdrawSheet: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("Withdraw to Lightning").font(.headline)
        Text("Paste a BOLT11 invoice and enter an amount in sats.")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Text("Invoice (BOLT11)")
        TextField("lnbc1…", text: $withdrawInvoice)
          .textFieldStyle(.roundedBorder)
          .font(.footnote)
          .onChange(of: withdrawInvoice) {
            if let sats = parseSatsFromBOLT11(withdrawInvoice) {
              withdrawAmount = String(sats)
            }
          }

        Text("Amount (sats)")
        TextField("0", text: $withdrawAmount)
          .textFieldStyle(.roundedBorder)
          .disabled(true)

        if isWithdrawing { ProgressView().padding(.vertical, 4) }
        if let err = withdrawError { Text(err).foregroundStyle(.red).font(.footnote) }

        HStack {
          Spacer()
          Button("Cancel") { showWithdraw = false }
          Button("Withdraw") {
            performWithdraw()
          }
          .buttonStyle(.borderedProminent)
          .disabled(withdrawInvoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding()
      .frame(minWidth: 360)
  }
    
  private func paymentSheet(for item: InvoiceItem) -> some View {
      VStack(spacing: 16) {
        InvoiceSheet(invoice: item.invoice)

        if let status = paymentStatus {
          Text(status)
            .font(.footnote)
            .foregroundStyle(status.hasPrefix("Error") ? .red : .secondary)
        }

        HStack {
          if isPolling { ProgressView().controlSize(.small) }
          Spacer()
          Button("I’ve paid – Refresh") {
              pollForPayment(item: item)
          }
        }
        .padding(.horizontal)
      }
      .padding()
      .frame(minWidth: 360)
  }

  // MARK: - Actions

  private func startMintingProcess() {
      guard let amount = Int64(mintAmountString), amount > 0 else { return }
      isRequestingQuote = true
      mintError = nil
      
      Task {
          let mint = activeMint
          let manager = wallet.manager
          let api = RealMintAPI(baseURL: mint)
          let engine = CocoBlindingEngine { mintURL in
            try await RealMintAPI(baseURL: mintURL).fetchKeyset()
          }
          let flow = MintCoordinator(manager: manager, api: api, blinding: engine)
          
          do {
              let (invoice, qid) = try await flow.topUp(mint: mint, amount: amount)
              
              await MainActor.run {
                  self.isRequestingQuote = false
                  self.showMintSheet = false // Close input sheet
                  
                  // Open Payment QR Sheet
                  self.invoiceItem = InvoiceItem(
                    invoice: invoice.trimmingCharacters(in: .whitespacesAndNewlines),
                    quoteId: qid
                  )
                  self.paymentStatus = "Waiting for payment…"
              }
              
              // Start polling automatically
              pollForPayment(item: InvoiceItem(invoice: invoice, quoteId: qid), flow: flow, amount: amount)
              
          } catch {
              await MainActor.run {
                  self.isRequestingQuote = false
                  self.mintError = error.localizedDescription
              }
          }
      }
  }
    
    private func pollForPayment(item: InvoiceItem, flow: MintCoordinator? = nil, amount: Int64 = 0) {
        self.isPolling = true
        // Re-create flow if missing (e.g. manual refresh button click)
        let mint = activeMint
        let activeFlow: MintCoordinator
        if let existing = flow {
            activeFlow = existing
        } else {
            let manager = wallet.manager
            let api = RealMintAPI(baseURL: mint)
            let engine = CocoBlindingEngine { u in try await RealMintAPI(baseURL: u).fetchKeyset() }
            activeFlow = MintCoordinator(manager: manager, api: api, blinding: engine)
        }
        
        // We need to know the amount to receive tokens.
        // In a real app, you'd store the pending Quote in DB with its amount.
        // Here, we rely on the closure capture or assume the user didn't change the input.
        let amountToMint = (amount > 0) ? amount : (Int64(mintAmountString) ?? 0)

        Task {
            do {
                try await activeFlow.pollUntilPaid(mint: mint, invoice: item.invoice, quoteId: item.quoteId)
                await MainActor.run { paymentStatus = "Paid. Fetching tokens…" }
                
                try await activeFlow.receiveTokens(mint: mint, invoice: item.invoice, quoteId: item.quoteId, amount: amountToMint)
                
                await MainActor.run {
                    paymentStatus = "Tokens received!"
                    isPolling = false
                    invoiceItem = nil // Close sheet on success
                }
            } catch {
                await MainActor.run {
                    paymentStatus = "Error: \(error.localizedDescription)"
                    isPolling = false
                }
            }
        }
    }
    
    private func performWithdraw() {
        Task {
          withdrawError = nil
          guard let amt = parseSatsFromBOLT11(withdrawInvoice) else { withdrawError = "Could not parse amount"; return }
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
        .monospacedDigit()
      Spacer()
        if proof.state != .unspent {
            Text(proof.state.rawValue)
                .font(.caption)
                .foregroundStyle(.orange)
        }
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
  switch unitChar {
  case "m": return amountVal * 100_000
  case "u": return amountVal * 100
  case "n": guard amountVal % 10 == 0 else { return nil }; return amountVal / 10
  case "p": guard amountVal % 10_000 == 0 else { return nil }; return amountVal / 10_000
  default: return nil
  }
}

private struct InvoiceItem: Identifiable {
  let id = UUID()
  let invoice: String
  let quoteId: String?
}
