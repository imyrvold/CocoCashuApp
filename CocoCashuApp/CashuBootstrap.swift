// CashuBootstrap.swift
import Foundation
import CocoCashuCore
import CocoCashuUI

@MainActor
enum CashuBootstrap {
  static func makeWallet() async -> ObservableWallet {
    // In-memory repos for a demo / prototyping:
    let proofRepo = InMemoryProofRepository()
    let quoteRepo = InMemoryQuoteRepository()
    let mintRepo  = InMemoryMintRepository()
    let counterRepo = InMemoryCounterRepository()

    // Minimal API stub – replace with your real mint API later.
    struct DemoAPI: MintAPI {
        func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?) {
            ("lnbc1p...fakeinvoice...", Date().addingTimeInterval(600), nil)
      }
      func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus { .paid }
      func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof] {
        [Proof(amount: 1000, mint: mint, secret: Data("secret".utf8))]
      }
      func melt(mint: MintURL, proofs: [Proof], amount: Int64, destination: String) async throws -> String {
        String(repeating: "00", count: 32)
      }
    }

    let api = RealMintAPI(baseURL: URL(string: "https://cashu.cz")!)
    let manager = CashuManager(
      proofRepo: proofRepo,
      mintRepo: mintRepo,
      quoteRepo: quoteRepo,
      counterRepo: counterRepo,
      api: api //DemoAPI()
    )

    return ObservableWallet(manager: manager)
  }
}

