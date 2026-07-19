// CashuBootstrap.swift
import Foundation
import CocoCashuCore
import CocoCashuUI

@MainActor
enum CashuBootstrap {
  static let defaultMint = URL(string: "https://cashu.cz")!

  static func makeWallet() async -> ObservableWallet {
      // 1. Repositories. Proofs and counters are disk-backed in the library, so
      // persistence (atomic writes, file protection, reserved/pending recovery,
      // legacy-format migration) lives next to the money model — the app no longer
      // hand-rolls it. Touch storeURL() first so the wallet directory exists and
      // is excluded from backups before the repository opens its file inside it.
    let proofRepo = FileProofRepository(url: storeURL())
    let quoteRepo = InMemoryQuoteRepository()
    // Persistent mint registry: multi-mint operations (scan-all, reconcile-all)
    // must know a mint even when no proofs currently sit there.
    let mintRepo  = FileMintRepository(url: mintsStoreURL())
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
      
      // 5. The proof repository loaded itself from disk on init (including
      //    migrating any legacy-format file), so there's nothing to restore and
      //    no save loop to wire — every mutation persists inside the repository.
      let wallet = ObservableWallet(manager: manager)

      // 6. Refresh
    await wallet.refreshAll()

      // 7. Register the default mint, then reconcile any proofs left `.pending`
      //    by a prior ambiguous failure or app kill (NUT-07 checkstate) at EVERY
      //    mint that holds them — a pending melt at a secondary mint must resolve
      //    too. Best-effort: unreachable mints leave their proofs pending.
      await manager.registerMint(defaultMint)
      await manager.reconcileAllPending()
      await wallet.refreshAll()

    return wallet
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

  private static func mintsStoreURL() -> URL {
    storeURL().deletingLastPathComponent().appendingPathComponent("mints.json")
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
    try? FileManager.default.removeItem(at: mintsStoreURL())
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
    // Keep mints.json: known mints aren't seed-specific, and the imported
    // seed's funds are most likely at those same mints — keeping them makes
    // the post-import "Scan for Lost Funds" find everything without the user
    // re-entering mint URLs.
  }
}

