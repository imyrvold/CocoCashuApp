import Foundation
import CocoCashuCore

enum MintExecError: Error { case requiresBlinding(String) }

final class MintCoordinator {
  let manager: CashuManager
  let api: MintAPI
    let blinding: BlindingEngine

    init(manager: CashuManager, api: MintAPI, blinding: BlindingEngine = NoopBlindingEngine()) {
      self.manager = manager
      self.api = api
      self.blinding = blinding
    }
    
  func topUp(mint: URL, amount: Int64) async throws -> (invoice: String, quoteId: String?) {
      print("MintCoordinator ggsd", #function)
    let q = try await api.requestMintQuote(mint: mint, amount: amount)
      print("MintCoordinator ggsd", #function, "q:", q)
    return (q.invoice, q.quoteId)
  }

    func pollUntilPaid(mint: URL, invoice: String?, quoteId: String?, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let status: QuoteStatus
        if let qid = quoteId, let real = api as? RealMintAPI {
          status = try await real.checkQuoteStatus(quoteId: qid)
        } else if let inv = invoice {
          status = try await api.checkQuoteStatus(mint: mint, invoice: inv)
        } else {
          throw CashuError.invalidQuote
        }
        print("pollUntilPaid status:", status)
        if status == .paid { return }
      try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    throw CashuError.network("Quote not paid in time")
  }
    
    /// Execute a PAID quote via NUT-04: plan -> blind -> execute -> unblind -> store
    private func executePaidQuote(mint: URL, quoteId: String, amount: Int64) async throws {
      guard let real = api as? RealMintAPI else {
        throw CashuError.protocolError("MintAPI does not support NUT-04 execute on this instance")
      }

      // 1) Choose denomination split for `amount` (e.g., 10 -> [8,2])
      let parts = try await blinding.planOutputs(amount: amount, mint: mint)

      // 2) Produce blinded outputs (B_) and keep blinding secrets internally
      let blinded = try await blinding.blind(parts: parts, mint: mint) // [BlindedOutput]

      // 3) Execute the mint: POST /v1/mint/bolt11 { quote, outputs }
      let dtos: [RealMintAPI.BlindedMessageDTO] = blinded.map { .init(amount: $0.amount, B_: $0.B_) }
      let sigs = try await real.executeMint(quoteId: quoteId, outputs: dtos) // [MintExecResponse.BlindSig]

      // 4) Unblind signatures into spendable Proofs
      let coreSigs: [BlindSignatureDTO] = sigs.map { BlindSignatureDTO(amount: $0.amount, C_: $0.C_, C: $0.C) }
      let proofs = try await blinding.unblind(signatures: coreSigs, for: parts, mint: mint)

      // 5) Store proofs and notify listeners
      try await manager.proofService.addNew(proofs)
      manager.events.emit(.proofsUpdated(mint: mint))
//      manager.events.emit(.quoteExecuted(quoteId))
    }

    func receiveTokens(mint: URL, invoice: String?, quoteId: String?, amount: Int64?) async throws {
      // First, try the simpler paths many mints still support
      do {
        let proofs: [Proof]
        if let qid = quoteId, let real = api as? RealMintAPI {
          proofs = try await real.requestTokens(quoteId: qid, mint: mint)
        } else if let inv = invoice {
          proofs = try await api.requestTokens(mint: mint, for: inv)
        } else {
          throw CashuError.invalidQuote
        }
        try await manager.proofService.addNew(proofs)
        manager.events.emit(.proofsUpdated(mint: mint))
        return
      } catch {
          // If redemption by quote/invoice failed, fall back to proper NUT-04 execution
          if let qid = quoteId, let amt = amount {
              print("MintCoordinator: falling back to NUT-04 execute for \(qid)")
              try await executePaidQuote(mint: mint, quoteId: qid, amount: amt)
              return
          }
          throw error
      }
    }
    
    // Split amount into binary parts (e.g., 10 -> [8, 2])
 /*   private func splitAmount(_ amount: Int64) -> [Int64] {
      var x = amount
      var parts: [Int64] = []
      var p: Int64 = 1
      while p <= x { p <<= 1 }
      p >>= 1
      while x > 0 {
        if p <= x { parts.append(p); x -= p }
        p >>= 1
      }
      return parts
    }

    // Temporary placeholder to compile: generates fake B_ values.
    // Replace with real blinding from CocoCashuCore.
    private func makePlaceholderBlindedOutputs(for parts: [Int64]) -> [RealMintAPI.BlindedMessageDTO] {
      func randomHex(_ n: Int) -> String { (0..<n).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined() }
      return parts.map { amt in RealMintAPI.BlindedMessageDTO(amount: amt, B_: randomHex(32)) }
    }

    // Try NUT-04 execute against the mint. This will *reach* the endpoint,
    // but cannot finish without real blinding/unblinding.
    private func tryExecuteMintIfSupported(mint: URL, quoteId: String, amount: Int64) async throws {
      guard let real = api as? RealMintAPI else { return }
      let parts = splitAmount(amount)
      let outputs = makePlaceholderBlindedOutputs(for: parts)
      _ = try await real.executeMint(quoteId: quoteId, outputs: outputs)
      // Server returned blind signatures; without your blinding secrets we cannot unblind into spendable Proofs.
      throw MintExecError.requiresBlinding(
        "Mint returned blind signatures. Integrate CocoCashuCore blinding: create real B_ for outputs and unblind C_/C to Proofs, then add via proofService.addNew(_:)."
      )
    }
    */
    
    
}
