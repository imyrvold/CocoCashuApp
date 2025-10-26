
import Foundation
import CocoCashuCore

struct RealMintAPI: MintAPI {
  let baseURL: URL
  let urlSession: URLSession = .shared

  // MARK: - Tolerant response models
  struct InfoResponse: Decodable { let name: String? }

  struct QuoteResponse: Decodable {
    let invoice: String
    let expiresAt: Date?
    let quoteId: String?

    enum CodingKeys: String, CodingKey {
      case invoice, expiresAt = "expires_at", quoteId
      // Alternate keys used by some mints
        case request, pr, quote, id, quote_id = "quote_id"
    }
      init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          // invoice candidates
          if let inv = try c.decodeIfPresent(String.self, forKey: .invoice) {
              invoice = inv
          } else if let inv = try c.decodeIfPresent(String.self, forKey: .request) {
              invoice = inv
          } else if let inv = try c.decodeIfPresent(String.self, forKey: .pr) {
              invoice = inv
          } else {
              throw DecodingError.keyNotFound(CodingKeys.invoice, .init(codingPath: decoder.codingPath, debugDescription: "No invoice field in quote response"))
          }
          // expires
          expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
          // quote id candidates (decode stepwise and tolerate numeric ids)
          let q1 = try? c.decodeIfPresent(String.self, forKey: .quoteId)
          let q2 = try? c.decodeIfPresent(String.self, forKey: .quote)
          let q3 = try? c.decodeIfPresent(String.self, forKey: .id)
          var q4: String? = nil
          if let s = try? c.decodeIfPresent(String.self, forKey: .quote_id) {
              q4 = s
          } else if let n = try? c.decodeIfPresent(Int.self, forKey: .quote_id) {
              q4 = String(n)
          }
          quoteId = q1 ?? q2 ?? q3 ?? q4
      }
  }

  struct StatusResponse: Decodable { let paid: Bool }

  struct MintTokenResponse: Decodable {
    struct MintProof: Decodable { let amount: Int64; let secret: String }
    let proofs: [MintProof]
  }

  struct MeltResponse: Decodable { let paid: Bool; let preimage: String?; let change: [MintTokenResponse.MintProof]? }

  // MARK: - MintAPI

  func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?) {
    // 0) Reachability check
      let _ : InfoResponse = try await getJSON(InfoResponse.self, path: "/v1/info")
      print("RealMintAPI reachability ok: /v1/info")
      print("RealMintAPI ggsd", #function, "1")
    // 1) Try GET style first: /v1/mint/quote/bolt11?amount=100&unit=sat
//    do {
//      let q: QuoteResponse = try await getJSON(QuoteResponse.self, path: "/v1/mint/quote/bolt11", query: ["amount": String(amount), "unit": "sat"])
//      return (q.invoice, q.expiresAt, q.quoteId)
//    } catch {
//      print("RealMintAPI GET quote failed, will try POST:", error)
//    }

      // 2) Fallback: POST style { amount: 100, unit: "sat" }
      do {
        let q: QuoteResponse = try await postJSON(QuoteResponse.self,
                                                 path: "/v1/mint/quote/bolt11",
                                                 body: ["amount": amount, "unit": "sat"])
          print("RealMintAPI ggsd", #function, "2")
        print("RealMintAPI POST quote ok")
        return (q.invoice, q.expiresAt, q.quoteId)
      } catch {
          print("RealMintAPI ggsd", #function, "3")
        print("RealMintAPI POST quote error:", error)
        throw error
      }
  }

  func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus {
    // Common: GET /v1/mint/quote/bolt11/status?invoice=...
    do {
        print("RealMintAPI ggsd", #function, "1")
      let s: StatusResponse = try await getJSON(StatusResponse.self, path: "/v1/mint/quote/bolt11/status", query: ["invoice": invoice])
        print("RealMintAPI ggsd", #function, "2")
      return s.paid ? .paid : .pending
    } catch {
        print("RealMintAPI ggsd", #function, "3", error)
      print("RealMintAPI status check error:", error)
      throw error
    }
  }

    // Some mints require quote id instead of invoice for status
/*    func checkQuoteStatus(quoteId: String) async throws -> QuoteStatus {
      let s: StatusResponse = try await getJSON(StatusResponse.self,
                                                path: "/v1/mint/quote/bolt11/status",
                                                query: ["quote": quoteId])
      return s.paid ? .paid : .pending
    }*/
    // Some mints require quote id instead of invoice for status
    func checkQuoteStatus(quoteId: String) async throws -> QuoteStatus {
      // Try the correct Cashu.cz pattern first
      do {
        let s: StatusResponse = try await getJSON(
          StatusResponse.self,
          path: "/v1/mint/quote/bolt11/\(quoteId)"
        )
        return s.paid ? .paid : .pending
      } catch {
        // Try older pattern: /quote/{quoteId}/bolt11
        do {
          let s: StatusResponse = try await getJSON(
            StatusResponse.self,
            path: "/v1/mint/quote/\(quoteId)/bolt11"
          )
          return s.paid ? .paid : .pending
        } catch {
          // Fallback: /v1/mint/quote/bolt11/status/{quoteId}
          do {
            let s: StatusResponse = try await getJSON(
              StatusResponse.self,
              path: "/v1/mint/quote/bolt11/status/\(quoteId)"
            )
            return s.paid ? .paid : .pending
          } catch {
            throw CashuError.network("Could not check status for quote id \(quoteId): \(error)")
          }
        }
      }
    }
    
    func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof] {
        // Typical: POST /v1/mint { invoice }
        let r: MintTokenResponse = try await postJSON(MintTokenResponse.self, path: "/v1/mint", body: ["invoice": invoice])
        return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) }
    }

    // Some mints deliver tokens by quote id instead of invoice
    func requestTokens(quoteId: String, mint: MintURL) async throws -> [Proof] {
      let r: MintTokenResponse = try await postJSON(MintTokenResponse.self,
                                                    path: "/v1/mint",
                                                    body: ["quote": quoteId])
      return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) }
    }

  func melt(mint: MintURL, proofs: [Proof], amount: Int64, destination: String) async throws -> (preimage: String, change: [Proof]?) {
    // Typical: POST /v1/melt/bolt11 { invoice, proofs }
    let payload: [String: Any] = [
      "invoice": destination,
      "proofs": proofs.map { ["amount": $0.amount, "secret": $0.secret.hexString] }
    ]
    let r: MeltResponse = try await postJSON(MeltResponse.self, path: "/v1/melt/bolt11", anyBody: payload)
    guard r.paid, let pre = r.preimage else { throw CashuError.protocolError("Melt failed or unpaid") }
    let changeProofs: [Proof]? = r.change?.map { mp in
      Proof(amount: mp.amount, mint: mint, secret: Data(hexOrBase64: mp.secret) ?? Data())
    }
    return (preimage: pre, change: changeProofs)
  }

  // MARK: - Networking helpers

  private func makeURL(path: String, query: [String: String]? = nil) -> URL {
    var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if let query { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
    return comps.url!
  }

  private func getJSON<T: Decodable>(_ type: T.Type, path: String, query: [String: String]? = nil) async throws -> T {
    let url = makeURL(path: path, query: query)
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, resp) = try await urlSession.data(for: req)
    try ensureOK(resp, url: url)
    return try decodeJSON(T.self, data: data)
  }

  private func postJSON<T: Decodable>(_ type: T.Type, path: String, body: [String: Any]) async throws -> T {
    try await postJSON(type, path: path, anyBody: body)
  }

  private func postJSON<T: Decodable>(_ type: T.Type, path: String, anyBody: [String: Any]) async throws -> T {
    let url = makeURL(path: path)
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.httpBody = try JSONSerialization.data(withJSONObject: anyBody, options: [])
    let (data, resp) = try await urlSession.data(for: req)
    try ensureOK(resp, url: url)
    return try decodeJSON(T.self, data: data)
  }

  private func ensureOK(_ resp: URLResponse, url: URL) throws {
    guard let http = resp as? HTTPURLResponse else { throw CashuError.network("No HTTPURLResponse for \(url)") }
    guard (200..<300).contains(http.statusCode) else {
      let msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
      throw CashuError.network("HTTP \(http.statusCode) (\(msg)) for \(url)")
    }
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
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
    let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
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
