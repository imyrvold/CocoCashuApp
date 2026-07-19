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
        
        // 1. Find a mint with enough balance (library logic: largest balance
        // that covers the amount — a melt spends proofs from ONE mint).
        let mintURL: URL
        do {
            mintURL = try await wallet.manager.selectMint(covering: amount)
        } catch {
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
    
    /// Amount preview from the invoice string. The decoder lives in
    /// CocoCashuCore (`BOLT11.amountSats`) with test vectors; MintService.spend
    /// still verifies the amount against the mint's quote and aborts on mismatch.
    private func decodeAmount(from invoice: String) -> Int64? {
        BOLT11.amountSats(from: invoice)
    }
}
