
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
    let rawTokenString: String?

    private enum CodingKeys: String, CodingKey { case proofs, token, tokens }

    private struct TokenObject: Decodable { let proofs: [MintProof]? }
    private struct TokenEntry: Decodable { let mint: String?; let proofs: [MintProof] }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      if let direct = try c.decodeIfPresent([MintProof].self, forKey: .proofs) {
        self.proofs = direct; self.rawTokenString = nil; return
      }
      if c.contains(.token) {
        if let obj = try? c.decode(TokenObject.self, forKey: .token), let p = obj.proofs {
          self.proofs = p; self.rawTokenString = nil; return
        }
        if let arr = try? c.decode([TokenEntry].self, forKey: .token), let first = arr.first {
          self.proofs = first.proofs; self.rawTokenString = nil; return
        }
        if let tokenString = try? c.decode(String.self, forKey: .token) { // cashuA... string
          print("RealMintAPI redeem: got string token (not parsed):", tokenString.prefix(32), "…")
          self.proofs = []; self.rawTokenString = tokenString; return
        }
      }
      if let arr = try? c.decode([TokenEntry].self, forKey: .tokens), let first = arr.first {
        self.proofs = first.proofs; self.rawTokenString = nil; return
      }
      throw DecodingError.keyNotFound(CodingKeys.proofs, .init(codingPath: decoder.codingPath, debugDescription: "No proofs in response"))
    }
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
        do {
          let r: MintTokenResponse = try await postJSON(MintTokenResponse.self, path: "/v1/mint", body: ["invoice": invoice])
          return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) }
        } catch {
          // Fallback body key used by some mints
          do {
            let r2: MintTokenResponse = try await postJSON(MintTokenResponse.self, path: "/v1/mint", body: ["payment_request": invoice])
            return r2.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) }
          } catch {
            throw error
          }
        }
    }

    // Some mints deliver tokens by quote id instead of invoice
    func requestTokens(quoteId: String, mint: MintURL) async throws -> [Proof] {
      // A) cashu.cz: POST /v1/mint/quote/bolt11/{quoteId} {}
      do {
        print("RealMintAPI redeem: POST /v1/mint/quote/bolt11/\(quoteId) {}")
        let r: MintTokenResponse = try await postJSON(MintTokenResponse.self,
                                                      path: "/v1/mint/quote/bolt11/\(quoteId)",
                                                      anyBody: [:])
        if !r.proofs.isEmpty { return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) } }
        if let s = r.rawTokenString, let parsed = parseCashuTokenString(s, mintURL: mint) { return parsed }
      } catch { print("RealMintAPI redeem POST quoteId path failed:", error) }

      // B) cashu.cz variant: POST /v1/mint/quote/\(id)/bolt11 {}
      do {
        print("RealMintAPI redeem: POST /v1/mint/quote/\(quoteId)/bolt11 {}")
        let r: MintTokenResponse = try await postJSON(MintTokenResponse.self,
                                                      path: "/v1/mint/quote/\(quoteId)/bolt11",
                                                      anyBody: [:])
        if !r.proofs.isEmpty { return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) } }
        if let s = r.rawTokenString, let parsed = parseCashuTokenString(s, mintURL: mint) { return parsed }
      } catch { print("RealMintAPI redeem POST quoteId/bolt11 failed:", error) }

      // C) GET /v1/mint/quote/bolt11/{quoteId} — may include { token: "cashuA..." }
      do {
        print("RealMintAPI redeem: GET /v1/mint/quote/bolt11/\(quoteId)")
        let data = try await getRaw(path: "/v1/mint/quote/bolt11/\(quoteId)")
        if let s = String(data: data, encoding: .utf8) { print("RealMintAPI redeem GET raw:", s) }
        // Try JSON -> { token: "cashuA..." } first
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tokenStr = obj["token"] as? String, let parsed = parseCashuTokenString(tokenStr, mintURL: mint) {
          return parsed
        }
        // Or decode structured proofs if present
        if let r = try? decodeJSON(MintTokenResponse.self, data: data), !r.proofs.isEmpty {
          return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) }
        }
      } catch { print("RealMintAPI redeem GET quoteId path failed:", error) }

      // D) Generic: POST /v1/mint with { quote: id }
      if let r: MintTokenResponse = try? await postJSON(MintTokenResponse.self,
                                                        path: "/v1/mint",
                                                        body: ["quote": quoteId]) {
        if !r.proofs.isEmpty { return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) } }
        if let s = r.rawTokenString, let parsed = parseCashuTokenString(s, mintURL: mint) { return parsed }
      }

      // E) Fallback keys
      if let r: MintTokenResponse = try? await postJSON(MintTokenResponse.self,
                                                        path: "/v1/mint",
                                                        body: ["quote_id": quoteId]) {
        if !r.proofs.isEmpty { return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) } }
        if let s = r.rawTokenString, let parsed = parseCashuTokenString(s, mintURL: mint) { return parsed }
      }
      if let r: MintTokenResponse = try? await postJSON(MintTokenResponse.self,
                                                        path: "/v1/mint",
                                                        body: ["id": quoteId]) {
        if !r.proofs.isEmpty { return r.proofs.map { Proof(amount: $0.amount, mint: mint, secret: Data(hexOrBase64: $0.secret) ?? Data()) } }
        if let s = r.rawTokenString, let parsed = parseCashuTokenString(s, mintURL: mint) { return parsed }
      }

      throw CashuError.network("Could not redeem tokens for quote id \(quoteId)")
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
    
    private func getRaw(path: String, query: [String: String]? = nil) async throws -> Data {
      let url = makeURL(path: path, query: query)
      var req = URLRequest(url: url)
      req.httpMethod = "GET"
      req.setValue("application/json", forHTTPHeaderField: "Accept")
      let (data, resp) = try await urlSession.data(for: req)
      try ensureOK(resp, url: url)
      return data
    }

    // Parse a string token like "cashuA..." into proofs
    private func parseCashuTokenString(_ token: String, mintURL: MintURL) -> [Proof]? {
      // Expect prefix "cashu" + version (e.g., 'A') followed by base64url payload
      guard token.lowercased().hasPrefix("cashu"), token.count > 6 else { return nil }
      let idx = token.index(token.startIndex, offsetBy: 6) // skip "cashu" + version char
      let b64url = String(token[idx...])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
      let padded: String = {
        let rem = b64url.count % 4
        return rem == 0 ? b64url : b64url + String(repeating: "=", count: 4 - rem)
      }()
      guard let data = Data(base64Encoded: padded) else { return nil }
        struct TokenRoot: Decodable {
            struct Entry: Decodable {
                let mint: String?
                let proofs: [MintTokenResponse.MintProof] }
            let token: [Entry]
        }
      guard let root = try? JSONDecoder().decode(TokenRoot.self, from: data), let first = root.token.first else { return nil }
      return first.proofs.map { Proof(amount: $0.amount, mint: mintURL, secret: Data(hexOrBase64: $0.secret) ?? Data()) }
    }

    // Models for NUT-04 execution
    struct BlindedMessageDTO: Encodable {
      let amount: Int64
      let B_: String   // blinded message
    }

    private struct MintExecRequest: Encodable {
      let quote: String
      let outputs: [BlindedMessageDTO]
    }

    struct MintExecResponse: Decodable {
      // NUT-04 calls these "signatures"; some older mints say "promises"
      struct BlindSig: Decodable { let amount: Int64; let C_: String?; let C: String? }

      let signatures: [BlindSig]?
      let promises: [BlindSig]?

      var all: [BlindSig] { signatures ?? promises ?? [] }
    }
    
    // MARK: - Modern NUT-04 redeem (for mints like cashu.cz)
    func redeemNUT04(quoteId: String, outputs: [BlindedMessageDTO]) async throws -> [MintExecResponse.BlindSig] {
        // Delegate to executeMint; kept for compatibility with callers
        return try await executeMint(quoteId: quoteId, outputs: outputs)
    }
    
    // MARK: - Keys (NUT-01) for blinding

    struct KeysResponse: Decodable {
      struct KeysetEntry: Decodable { let id: String?; let keys: [String:String] }
      let keys: [String:String]?
      let keysets: [KeysetEntry]?
    }

    // Convert whatever the mint gives us into Keyset(amount:Int64 -> pubkeyHex)
    func fetchKeyset() async throws -> Keyset {
      let r: KeysResponse = try await getJSON(KeysResponse.self, path: "/v1/keys")
      if let ks = r.keysets?.first {
          let raw = ks.keys
        var map: [Int64:String] = [:]
        for (k,v) in raw { if let a = Int64(k) { map[a] = v } }
        return Keyset(id: ks.id ?? baseURL.absoluteString, keys: map)
      }
      if let raw = r.keys {
        var map: [Int64:String] = [:]
        for (k,v) in raw { if let a = Int64(k) { map[a] = v } }
        return Keyset(id: baseURL.absoluteString, keys: map)
      }
      // Some mints expose { "1": "02ab...", "2": "03cd...", ... } at the top level
      if let obj = try? await getRaw(path: "/v1/keys"),
         let top = try? JSONSerialization.jsonObject(with: obj) as? [String:Any] {
        var map: [Int64:String] = [:]
        for (k,v) in top { if let a = Int64(k), let s = v as? String { map[a] = s } }
        if !map.isEmpty { return Keyset(id: baseURL.absoluteString, keys: map) }
      }
      throw CashuError.protocolError("Mint /v1/keys did not contain a usable keyset")
    }
    
    /// Execute a PAID mint quote by submitting blinded outputs.
    /// Returns the raw blind signatures; you must unblind to create Proofs.
    func executeMint(quoteId: String, outputs: [BlindedMessageDTO]) async throws -> [MintExecResponse.BlindSig] {
        // We will try several endpoint/body variants to interop with differing mint deployments.
        let pathA = "/v1/mint/quote/bolt11/\(quoteId)"       // NUT-04 path-param style
        let pathB = "/v1/mint/quote/\(quoteId)/bolt11"       // legacy swapped segments
        let pathC = "/v1/mint/bolt11"                         // body carries the quote id

        // Bodies
        let outputs_B_: [[String: Any]] = outputs.map { [
            "amount": $0.amount,
            "B_": $0.B_
        ]}
        let outputs_B: [[String: Any]] = outputs.map { [
            "amount": $0.amount,
            "B": $0.B_
        ]}

        // Lazy keyset fetch (only if needed)
        func outputsWithId(_ arr: [[String: Any]], id: String) -> [[String: Any]] {
            arr.map { o in
                var m = o; m["id"] = id; return m
            }
        }

        // Try helpers
        func tryPOST(path: String, body: [String: Any]) async throws -> [MintExecResponse.BlindSig] {
            let r: MintExecResponse = try await postJSON(MintExecResponse.self, path: path, anyBody: body)
            return r.all
        }

        // 1) POST /v1/mint/quote/bolt11/{quote} with { outputs: [{amount,B_}] }
        do {
            return try await tryPOST(path: pathA, body: ["outputs": outputs_B_])
        } catch {}

        // 2) Same path, key "B"
        do {
            return try await tryPOST(path: pathA, body: ["outputs": outputs_B])
        } catch {}

        // 3) Legacy path: /v1/mint/quote/{quote}/bolt11, with B_
        do {
            return try await tryPOST(path: pathB, body: ["outputs": outputs_B_])
        } catch {}

        // 4) Legacy path + key "B"
        do {
            return try await tryPOST(path: pathB, body: ["outputs": outputs_B])
        } catch {}

        // 5) Body carries the quote id: POST /v1/mint/bolt11 { quote, outputs: [{amount,B_}] }
        do {
            return try await tryPOST(path: pathC, body: ["quote": quoteId, "outputs": outputs_B_])
        } catch {}

        // 6) Same with key "B"
        do {
            return try await tryPOST(path: pathC, body: ["quote": quoteId, "outputs": outputs_B])
        } catch {}

        // 7) Some servers require keyset id per output. Fetch and retry.
        let keyset = try? await fetchKeyset()
        if let kid = keyset?.id {
            // 7a) Path A + id + B_
            do {
                return try await tryPOST(path: pathA, body: ["outputs": outputsWithId(outputs_B_, id: kid)])
            } catch {}
            // 7b) Path A + id + B
            do {
                return try await tryPOST(path: pathA, body: ["outputs": outputsWithId(outputs_B, id: kid)])
            } catch {}
            // 7c) Path C with quote in body + id + B_
            do {
                return try await tryPOST(path: pathC, body: ["quote": quoteId, "outputs": outputsWithId(outputs_B_, id: kid)])
            } catch {}
            // 7d) Path C with quote in body + id + B
            do {
                return try await tryPOST(path: pathC, body: ["quote": quoteId, "outputs": outputsWithId(outputs_B, id: kid)])
            } catch {}
        }

        throw CashuError.network("NUT-04 execute failed for quote \(quoteId) on all endpoint variants")
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
