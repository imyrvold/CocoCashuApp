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
  func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?) {
    ("lnbc1p...fakeinvoice...", Date().addingTimeInterval(600), nil)
  }

  func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus { .paid }

  func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof] {
    [Proof(amount: 1000, mint: mint, secret: Data("secret".utf8))]
  }

  // ⬇️ Update this method to match the protocol
  func melt(mint: MintURL, proofs: [Proof], amount: Int64, destination: String) async throws -> (preimage: String, change: [Proof]?) {
    return (String(repeating: "00", count: 32), nil)
  }
}

func makeManager() async throws -> CashuManager {
  let proofs = InMemoryProofRepository()
  let quotes = InMemoryQuoteRepository()
  let mints  = InMemoryMintRepository()
  let counters = InMemoryCounterRepository()
  let api = DemoAPI()
  return CashuManager(
    proofRepo: proofs,
    mintRepo: mints,
    quoteRepo: quotes,
    counterRepo: counters,
    api: api
  )
}

