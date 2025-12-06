//
//  ContentView.swift
//  CocoCashuApp
//
//  Created by Ivan C Myrvold on 18/10/2025.
//

import SwiftUI
import CocoCashuCore
import CocoCashuUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

struct DemoAPI: MintAPI {
    func requestMeltQuote(mint: CocoCashuCore.MintURL, amount: Int64, destination: String) async throws -> (quoteId: String, feeReserve: Int64) {
        ("", 0)
    }
    
    func executeMelt(mint: CocoCashuCore.MintURL, quoteId: String, inputs: [CocoCashuCore.Proof], outputs: [CocoCashuCore.BlindedOutput]) async throws -> (preimage: String, change: [CocoCashuCore.BlindSignatureDTO]?) {
        ("", nil)
    }
    
  func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?) {
    ("lnbc1p...fakeinvoice...", Date().addingTimeInterval(600), nil)
  }

  func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus { .paid }

  func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof] {
    [Proof(amount: 1000, mint: mint, secret: Data("secret".utf8),C: "", keysetId: "")]
  }

  // ⬇️ Update this method to match the protocol
  func melt(mint: MintURL, proofs: [Proof], amount: Int64, destination: String) async throws -> (preimage: String, change: [Proof]?) {
    return (String(repeating: "00", count: 32), nil)
  }
}


