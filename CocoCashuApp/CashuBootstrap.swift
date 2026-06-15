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
    let C: String
    let keysetId: String
  }

  static let defaultMint = URL(string: "https://cashu.cz")!

  static func makeWallet() async -> ObservableWallet {
      // 1. Repositories
    let proofRepo = InMemoryProofRepository()
    let quoteRepo = InMemoryQuoteRepository()
    let mintRepo  = InMemoryMintRepository()
    // Persistent NUT-13 derivation counter: survives restarts so deterministic
    // secrets are never reused and minted proofs stay restorable from the seed.
    let counterRepo = FileCounterRepository(url: counterStoreURL())

      let api = RealMintAPI(baseURL: defaultMint)
      
      // 2. SEED LOGIC
      // We attempt to retrieve an existing seed. If none exists, we create a new wallet.
      let seedData: Data
      
      do {
          if let phrase = SeedManager.shared.retrieveFromKeychain() {
              seedData = try SeedManager.shared.seed(from: phrase)
          } else {
              let newPhrase = try SeedManager.shared.generateNewMnemonic()
              try SeedManager.shared.saveToKeychain(phrase: newPhrase)
              seedData = try SeedManager.shared.seed(from: newPhrase)
          }
      } catch {
          fatalError("CashuBootstrap: Failed to initialize wallet seed — \(error.localizedDescription)")
      }
      
      // 3. Initialize Engine with Seed (Replaces the old closure-based init)
      // Ensure your CocoBlindingEngine in the library now has 'init(seed: Data)'
      let engine = CocoBlindingEngine(seed: seedData, counterRepo: counterRepo) { mintURL in
          let tempApi = RealMintAPI(baseURL: mintURL)
          return try await tempApi.fetchKeyset()
      }
      
      // 4. Create Manager
      let manager = CashuManager(
      proofRepo: proofRepo,
      mintRepo: mintRepo,
      quoteRepo: quoteRepo,
      counterRepo: counterRepo,
      api: api,
      blinding: engine
    )
      
      // 5. Restore old "random" proofs (Legacy support)
    await restoreProofs(manager: manager)
      
      // 2. ENABLE AUTO-SAVE (New!)
      // Whenever proofs change (mint, spend, restore), we save to disk.
      Task {
          for await _ in manager.events.values {
              // We save on ANY event for simplicity, or filter for ProofAdded/ProofSpent
              await saveWallet(manager: manager)
          }
      }

      let wallet = ObservableWallet(manager: manager)

      // 6. Refresh
    await wallet.refreshAll()
      
    return wallet
  }
    
    private static func saveWallet(manager: CashuManager) async {
        // Get all proofs (spent and unspent) from the repo
        // Note: We need a way to get ALL proofs.
        // If InMemoryRepository only exposes 'fetchUnspent', we might miss some history,
        // but for a simple wallet, saving unspent is the most important.
        // Ideally, add 'getAll()' to your Repository protocol.
        // For now, let's save the 'unspent' ones to keep your balance safe.
        
        guard let proofs = try? await manager.proofService.getUnspent(mint: nil) else { return }
        
        let storedItems = proofs.map { p in
            StoredProof(
                amount: p.amount,
                mint: p.mint.absoluteString,
                secretBase64: p.secret.base64EncodedString(),
                C: p.C,
                keysetId: p.keysetId
            )
        }
        
        let url = storeURL()
        if let data = try? JSONEncoder().encode(storedItems) {
            try? data.write(to: url)
            // print("💾 Saved \(storedItems.count) proofs to disk")
        }
    }

  private static func restoreProofs(manager: CashuManager) async {
    let url = storeURL()
    guard let data = try? Data(contentsOf: url) else { return }
    let decoder = JSONDecoder()
    guard let stored = try? decoder.decode([StoredProof].self, from: data) else { return }

    let proofs: [Proof] = stored.compactMap { item in
      guard let mintURL = URL(string: item.mint),
            let secret = Data(base64Encoded: item.secretBase64) else { return nil }
        return Proof(amount: item.amount, mint: mintURL, secret: secret, C: item.C, keysetId: item.keysetId)
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
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("proofs.json")
  }

  private static func counterStoreURL() -> URL {
    storeURL().deletingLastPathComponent().appendingPathComponent("counters.json")
  }

  // MARK: - Reset

  /// Clears the stored balance only. Keeps the seed AND the NUT-13 counter, so
  /// future derivations continue forward and never reuse blinded outputs.
  /// Safe, but does not recover indices the mint has already seen.
  static func clearBalance() {
    try? FileManager.default.removeItem(at: storeURL())
  }

  /// Full wallet reset: wipes balance, the NUT-13 counter, and the seed from the
  /// Keychain. On next launch a brand-new seed is generated with a fresh counter,
  /// giving a clean derivation space (no output-reuse collisions).
  static func resetWalletNewSeed() {
    try? FileManager.default.removeItem(at: storeURL())
    try? FileManager.default.removeItem(at: counterStoreURL())
    SeedManager.shared.deleteFromKeychain()
  }
}

