//
//  MeltView.swift
//  CocoCashuApp
//
//  Created by Ivan C Myrvold on 26/12/2025.
//

import SwiftUI
import CocoCashuCore
import CocoCashuUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct MeltView: View {
    @Bindable var wallet: ObservableWallet
    @Environment(\.dismiss) var dismiss
    
    @State private var invoice: String = ""
    @State private var statusMessage: String = ""
    @State private var isProcessing = false
    @State private var amountToPay: Int64? = nil
    @State private var showingScanner = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Lightning Invoice") {
                    TextField("lnbc...", text: $invoice, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: invoice) { _, newValue in
                            // Auto-detect amount when user pastes
                            if let amt = decodeAmount(from: newValue) {
                                amountToPay = amt
                                statusMessage = "Invoice for \(amt) sats"
                            } else if !newValue.isEmpty {
                                statusMessage = "Could not detect amount (Is this a valid BOLT11?)"
                                amountToPay = nil
                            }
                        }
                    
                    HStack {
                        Button("Paste") { pasteFromClipboard() }
                            .buttonStyle(.borderless)
                        
                        Spacer()
                        
                        #if os(iOS)
                        Button {
                            showingScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderless)
                        #endif
                    }
                }
                
                if let amt = amountToPay {
                    Section {
                        Text("Amount: \(amt) sats")
                            .font(.headline)
                    }
                }
                
                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .foregroundStyle(statusMessage.contains("Success") ? .green : .orange)
                    }
                }
                
                Section {
                    Button(action: { Task { await payInvoice() } }) {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Pay Invoice")
                        }
                    }
                    .disabled(invoice.isEmpty || amountToPay == nil || isProcessing)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Pay Invoice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingScanner) {
                QRScannerView(isPresenting: $showingScanner) { code in
                    self.invoice = code // This triggers the onChange logic automatically!
                }
            }
            #endif
            // Form size on macOS
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 400)
            #endif

            .padding(.horizontal)
        }
    }
    
    // MARK: - Logic
    
    private func payInvoice() async {
        guard let amount = amountToPay else { return }
        
        isProcessing = true
        statusMessage = "Processing..."
        
        // 1. Find a mint with enough balance
        // Logic: Pick the mint with the largest balance for simplicity
        // (A real app might define "smart routing" or let the user pick)
        guard let bestMint = wallet.proofsByMint
            .map({ (url: $0.key, bal: $0.value.map(\.amount).reduce(0, +)) })
            .sorted(by: { $0.bal > $1.bal })
            .first,
              let mintURL = URL(string: bestMint.url),
              bestMint.bal >= amount else {
            
            statusMessage = "Insufficient funds in any single mint."
            isProcessing = false
            return
        }
        
        do {
            // 2. Execute Melt. `spend` submits the melt and, if the mint reports the
            // Lightning payment still in flight (PENDING), polls until it settles.
            let result = try await wallet.manager.mintService.spend(amount: amount, from: mintURL, to: invoice)

            switch result {
            case .paid:
                statusMessage = "Success! Payment sent."
                isProcessing = false
                // Auto-close after short delay
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dismiss()

            case .pending:
                // Accepted but not yet settled — this is NOT a failure. The funds
                // are held aside and the payment will confirm on its own; the app
                // reconciles it automatically.
                statusMessage = "Payment is processing — the mint is still settling it. You can close this; it will confirm automatically."
                isProcessing = false
            }

        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
            isProcessing = false
        }
    }
    
    // MARK: - Cross-Platform Clipboard Helper
    
    private func pasteFromClipboard() {
        var pastedString: String?
        
        #if os(iOS)
        pastedString = UIPasteboard.general.string
        #elseif os(macOS)
        pastedString = NSPasteboard.general.string(forType: .string)
        #endif
        
        if let str = pastedString {
            // Clean up prefixes if present
            let clean = str
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "lightning:", with: "", options: .caseInsensitive)
            
            self.invoice = clean
        }
    }
    
    // MARK: - Simple BOLT11 Decoder Helper
    
    /// Extract amount in Satoshis from a BOLT11 string (Regex)
    private func decodeAmount(from invoice: String) -> Int64? {
        let lower = invoice.lowercased()
        guard lower.hasPrefix("ln") else { return nil }
        
        // Regex to find the "Amount" section (e.g. lnbc100n...)
        // Structure: "ln" + (network: bc/tb/crt) + (amount_number) + (multiplier) + ...
        // Example: lnbc100n... -> 100 nano
        
        let pattern = "^ln[a-z]+(\\d+)([pnum])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        
        let range = NSRange(location: 0, length: lower.utf16.count)
        guard let match = regex.firstMatch(in: lower, range: range) else { return nil }
        
        // Extract Number
        guard let r1 = Range(match.range(at: 1), in: lower),
              let r2 = Range(match.range(at: 2), in: lower) else { return nil }
        
        let multiplierChar = String(lower[r2])

        // BOLT11 Multipliers to Satoshis (1 BTC = 100,000,000 sats), computed in
        // INTEGER math. The old Double math silently truncated fractional-sat
        // invoices (lnbc105n = 10.5 sats became "10"), so the app displayed and
        // attempted an amount that wasn't what the invoice asked. Reject any
        // invoice that isn't a whole number of sats instead of rounding it.
        // Note the client parse is only a UI preview — MintService.spend verifies
        // it against the mint's quoted amount and aborts on mismatch.
        guard let value = Int64(lower[r1]), value > 0 else { return nil }

        var sats: Int64
        switch multiplierChar {
        case "m":                                // milli-BTC = 100,000 sats
            sats = value * 100_000
        case "u":                                // micro-BTC = 100 sats
            sats = value * 100
        case "n":                                // nano-BTC = 0.1 sat → whole sats only for multiples of 10
            guard value % 10 == 0 else { return nil }
            sats = value / 10
        case "p":                                // pico-BTC = 0.0001 sat → multiples of 10,000
            guard value % 10_000 == 0 else { return nil }
            sats = value / 10_000
        default: return nil
        }

        return sats >= 1 ? sats : nil
    }
}
