// CashuBootstrap.swift
import Foundation
import CocoCashuCore
import CocoCashuUI

@MainActor
enum CashuBootstrap {
  // Local helper for restoring proofs (matches ObservableWallet.persistProofs)
  private struct StoredProof: Codable {
    let amount: Int64
    let mint: String
    let secretBase64: String
  }

  static func makeWallet() async -> ObservableWallet {
    // In-memory repos for a demo / prototyping:
    let proofRepo = InMemoryProofRepository()
    let quoteRepo = InMemoryQuoteRepository()
    let mintRepo  = InMemoryMintRepository()
    let counterRepo = InMemoryCounterRepository()

    // Minimal API stub – replace with your real mint API later.
    struct DemoAPI: MintAPI {
        func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?) {
          ("lnbc1p...fakeinvoice...", Date().addingTimeInterval(600), "demo-quote-id")
        }
        
        
        func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus { .paid }
        
        func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof] {
          [Proof(amount: 100, mint: mint, secret: Data("secret".utf8))]
        }
        
        func melt(mint: MintURL, proofs: [Proof], amount: Int64, destination: String) async throws -> (preimage: String, change: [Proof]?) {
          return (String(repeating: "00", count: 32), nil)
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

    let wallet = ObservableWallet(manager: manager)
    await restoreProofs(manager: manager)
    await wallet.refreshAll()
    return wallet
  }

  private static func restoreProofs(manager: CashuManager) async {
    let url = storeURL()
    guard let data = try? Data(contentsOf: url) else { return }
    let decoder = JSONDecoder()
    guard let stored = try? decoder.decode([StoredProof].self, from: data) else { return }

    let proofs: [Proof] = stored.compactMap { item in
      guard let mintURL = URL(string: item.mint),
            let secret = Data(base64Encoded: item.secretBase64) else { return nil }
      return Proof(amount: item.amount, mint: mintURL, secret: secret)
    }
    guard !proofs.isEmpty else { return }

    do {
      try await manager.proofService.addNew(proofs)
    } catch {
      print("CashuBootstrap restoreProofs error:", error)
    }
  }

  private static func storeURL() -> URL {
    let fm = FileManager.default
    let base: URL
    if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true) {
      base = appSupport
    } else {
      base = URL(fileURLWithPath: NSTemporaryDirectory())
    }
    let dir = base.appendingPathComponent("CocoCashuWallet", isDirectory: true)
    return dir.appendingPathComponent("proofs.json")
  }
}

