// CashuBootstrap.swift
import Foundation
import CocoCashuCore
import CocoCashuUI

/// The app's composition root, reduced to the two genuinely app-level choices:
/// which mint is the default and where wallet files live. All wiring
/// (repositories, seed handling, engine, launch reconciliation) is done by the
/// library's `CashuWalletFactory`.
@MainActor
enum CashuBootstrap {
  static let defaultMint = URL(string: "https://cashu.cz")!
  static let storage = WalletStorage.standard()

  static func makeWallet() async -> ObservableWallet {
    do {
      return try await CashuWalletFactory.makeWallet(defaultMint: defaultMint, storage: storage)
    } catch {
      // A throw here means the SEED could not be safely established (keychain
      // unreadable, entropy failure). Fail closed: crashing is better than
      // generating a fresh seed over the real one.
      fatalError("CashuBootstrap: Failed to initialize wallet seed — \(error.localizedDescription)")
    }
  }

  // MARK: - Reset

  /// Clears the stored balance only. Keeps the seed AND the NUT-13 counter, so
  /// future derivations continue forward and never reuse blinded outputs.
  static func clearBalance() {
    storage.clearBalance()
  }

  /// Full wallet reset: wipes all wallet files and the seed from the Keychain.
  /// On next launch a brand-new seed is generated with a fresh counter.
  static func resetWalletNewSeed() {
    storage.resetForNewSeed()
    SeedManager.shared.deleteFromKeychain()
  }

  /// Called after a DIFFERENT seed was imported into the Keychain: wipe the old
  /// seed's state but keep the newly saved seed (and the mint registry — see
  /// WalletStorage.resetForImportedSeed).
  static func resetStateForImportedSeed() {
    storage.resetForImportedSeed()
  }
}
