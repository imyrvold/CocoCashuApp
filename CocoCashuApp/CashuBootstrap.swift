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
    // Persisted so `.pending` proofs (melt outcome unknown) survive an app kill and
    // can be reconciled on next launch. Absent in legacy files → treated as unspent.
    var state: ProofState?
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
          // retrieveFromKeychain returns nil ONLY on a positive "no item exists";
          // any other keychain failure throws, and we fail closed (crash) below —
          // generating a new seed on a transient keychain error would overwrite
          // and permanently destroy the real one.
          if let phrase = try SeedManager.shared.retrieveFromKeychain() {
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

      // 7. Reconcile any melt left `.pending` by a prior ambiguous failure or app
      //    kill (NUT-07 checkstate), then refresh so resolved proofs reflect in the
      //    balance. Best-effort: if the mint is unreachable, they stay pending.
      try? await manager.mintService.reconcilePending(mint: defaultMint)
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
        
        // Persist unspent, pending AND reserved proofs. Pending ones (operation
        // outcome unknown) must survive a kill so `reconcilePending` resolves them
        // next launch. Reserved ones are mid-operation money — omitting them (the
        // old behavior) meant an app kill during a send erased them from disk.
        let unspent = (try? await manager.proofService.getUnspent(mint: nil)) ?? []
        let pending = (try? await manager.proofService.pendingProofs(mint: nil)) ?? []
        let reserved = (try? await manager.proofService.reservedProofs(mint: nil)) ?? []
        let proofs = unspent + pending + reserved

        let storedItems = proofs.map { p in
            StoredProof(
                amount: p.amount,
                mint: p.mint.absoluteString,
                secretBase64: p.secret.base64EncodedString(),
                C: p.C,
                keysetId: p.keysetId,
                state: p.state
            )
        }
        
        let url = storeURL()
        if let data = try? JSONEncoder().encode(storedItems) {
            // Proofs are bearer money: write with complete file protection so the
            // file is unreadable while the device is locked, and atomically to
            // avoid a torn write corrupting the balance.
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try? data.write(to: url, options: options)
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
        // A proof persisted as `.reserved` belonged to an operation the app died in
        // the middle of — its outcome is unknown, so load it as `.pending` and let
        // the launch NUT-07 reconciliation decide (spent → finalize, else release).
        var state = item.state ?? .unspent
        if state == .reserved { state = .pending }
        return Proof(amount: item.amount, mint: mintURL, secret: secret, C: item.C, keysetId: item.keysetId, state: state)
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
    var dir = base.appendingPathComponent("CocoCashuWallet", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // Keep the wallet directory (proofs, counters, history) out of iCloud/iTunes
    // backups so bearer proofs and the derivation counter can't be exfiltrated
    // from a backup or restored onto another device.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
    return dir.appendingPathComponent("proofs.json")
  }

  private static func counterStoreURL() -> URL {
    storeURL().deletingLastPathComponent().appendingPathComponent("counters.json")
  }

  private static func historyStoreURL() -> URL {
    storeURL().deletingLastPathComponent().appendingPathComponent("history.json")
  }

  // MARK: - Reset

  /// Clears the stored balance only. Keeps the seed AND the NUT-13 counter, so
  /// future derivations continue forward and never reuse blinded outputs.
  /// Safe, but does not recover indices the mint has already seen.
  static func clearBalance() {
    try? FileManager.default.removeItem(at: storeURL())
  }

  /// Full wallet reset: wipes balance, the NUT-13 counter, the transaction
  /// history, and the seed from the Keychain. On next launch a brand-new seed is
  /// generated with a fresh counter, giving a clean derivation space. History
  /// must go too — amounts/timestamps surviving a "full" reset would leak the
  /// old wallet's activity onto the supposedly clean one.
  static func resetWalletNewSeed() {
    try? FileManager.default.removeItem(at: storeURL())
    try? FileManager.default.removeItem(at: counterStoreURL())
    try? FileManager.default.removeItem(at: historyStoreURL())
    SeedManager.shared.deleteFromKeychain()
  }

  /// Called after a DIFFERENT seed was imported into the Keychain: wipe every
  /// piece of state that belongs to the old seed (proofs, counters, history) but
  /// keep the newly saved seed. Without this, the app keeps the old proofs and —
  /// until relaunch — keeps deriving from the old seed, so a user could mint
  /// funds on seed A while BackupView shows them seed B as "their backup".
  static func resetStateForImportedSeed() {
    try? FileManager.default.removeItem(at: storeURL())
    try? FileManager.default.removeItem(at: counterStoreURL())
    try? FileManager.default.removeItem(at: historyStoreURL())
  }
}

