import Foundation
import CocoCashuCore

final class MintCoordinator {
  let manager: CashuManager
  let api: MintAPI
  init(manager: CashuManager, api: MintAPI) { self.manager = manager; self.api = api }

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

    func receiveTokens(mint: URL, invoice: String?, quoteId: String?) async throws {
      let proofs: [Proof]
      if let qid = quoteId, let real = api as? RealMintAPI {
        proofs = try await real.requestTokens(quoteId: qid, mint: mint)
      } else if let inv = invoice {
        proofs = try await api.requestTokens(mint: mint, for: inv)
      } else {
        throw CashuError.invalidQuote
      }
     try await manager.proofService.addNew(proofs)
  }
}
