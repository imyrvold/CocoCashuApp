import Foundation
import CocoCashuCore

struct RealMintAPI: MintAPI {
  let baseURL: URL
  let urlSession: URLSession = .shared

  // MARK: Types you can tweak to your mint’s schema
  struct QuoteResponse: Decodable {
    let invoice: String
    let expiresAt: Date?
    let quoteId: String?   // some mints use id, token, or quote
    enum CodingKeys: String, CodingKey {
      case invoice
      case expiresAt = "expires_at"
      case quoteId = "quote" // adjust to your mint: "quote", "id", "quote_id"
    }
  }

  struct StatusResponse: Decodable {
    let paid: Bool
    enum CodingKeys: String, CodingKey { case paid }
  }

  struct MintTokenResponse: Decodable {
    let proofs: [MintProof]
    struct MintProof: Decodable {
      let amount: Int64
      let secret: String     // hex or base64; adjust decode below if needed
      // you might also receive C, D, Y etc (Cashu-specific fields)
    }
  }

  struct MeltResponse: Decodable {
    let paid: Bool
    let preimage: String?
  }

  // MARK: MintAPI

  func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?) {
    // Example: POST { amount } to /v1/mint/quote/bolt11
    // Adjust path/keys for your mint
    let url = baseURL.appendingPathComponent("v1/mint/quote/bolt11")
    let body = ["amount": amount]
    let resp: QuoteResponse = try await postJSON(url: url, body: body)
    return (invoice: resp.invoice, expiresAt: resp.expiresAt, quoteId: resp.quoteId)
  }

  func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus {
    // Some mints require a quoteId. If you have it on your Quote, use that instead.
    // Example with invoice hash: GET /v1/mint/quote/bolt11/status?invoice=...
    var comps = URLComponents(url: baseURL.appendingPathComponent("v1/mint/quote/bolt11/status"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [URLQueryItem(name: "invoice", value: invoice)]
    let url = comps.url!
    let status: StatusResponse = try await getJSON(url: url)
    return status.paid ? .paid : .pending
  }

  func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof] {
    // Example: POST /v1/mint with { invoice }
    let url = baseURL.appendingPathComponent("v1/mint")
    let body = ["invoice": invoice]
    let minted: MintTokenResponse = try await postJSON(url: url, body: body)

    // Map server proofs -> demo Proof model
    return minted.proofs.map { mp in
      Proof(
        amount: mp.amount,
        mint: mint,
        secret: Data(hexOrBase64: mp.secret) ?? Data()
      )
    }
  }

  func melt(mint: MintURL, proofs: [Proof], amount: Int64, destination: String) async throws -> String {
    // Example: POST /v1/melt/bolt11 with { invoice, proofs }
    let url = baseURL.appendingPathComponent("v1/melt/bolt11")

    let payload: [String: Any] = [
      "invoice": destination,
      "proofs": proofs.map { ["amount": $0.amount, "secret": $0.secret.hexString] }
      // Adjust to actual proof payload your mint expects
    ]

    let resp: MeltResponse = try await postJSON(url: url, anyBody: payload)
    guard resp.paid, let preimage = resp.preimage else {
      throw CashuError.protocolError("Melt failed or unpaid")
    }
    return preimage
  }

  // MARK: - Networking helpers

  private func getJSON<T: Decodable>(url: URL) async throws -> T {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await urlSession.data(for: req)
    try ensureOK(response)
    return try decodeJSON(data)
  }

  private func postJSON<T: Decodable>(url: URL, body: [String: Any]) async throws -> T {
    try await postJSON(url: url, anyBody: body)
  }

  private func postJSON<T: Decodable>(url: URL, anyBody: [String: Any]) async throws -> T {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.httpBody = try JSONSerialization.data(withJSONObject: anyBody, options: [])
    let (data, response) = try await urlSession.data(for: req)
    try ensureOK(response)
    return try decodeJSON(data)
  }

  private func ensureOK(_ resp: URLResponse) throws {
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw CashuError.network("HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? -1)")
    }
  }

  private func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try dec.decode(T.self, from: data)
  }
}

// MARK: - Small helpers

private extension Data {
  /// Try hex first, fall back to base64.
  init?(hexOrBase64: String) {
    if let d = Data(hex: hexOrBase64) { self = d; return }
    if let d = Data(base64Encoded: hexOrBase64) { self = d; return }
    return nil
  }
  init?(hex: String) {
    let s = hex.dropPrefixIfNeeded("0x")
    let len = s.count
    guard len % 2 == 0 else { return nil }
    var data = Data(capacity: len/2)
    var idx = s.startIndex
    while idx < s.endIndex {
      let next = s.index(idx, offsetBy: 2)
      guard next <= s.endIndex else { return nil }
      let byteStr = s[idx..<next]
      guard let b = UInt8(byteStr, radix: 16) else { return nil }
      data.append(b)
      idx = next
    }
    self = data
  }
  var hexString: String { self.map { String(format: "%02x", $0) }.joined() }
}

private extension StringProtocol {
  func dropPrefixIfNeeded(_ p: String) -> SubSequence {
    hasPrefix(p) ? dropFirst(p.count) : self[...]
  }
}
