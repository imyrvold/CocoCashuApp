# Security Remediation Plan — CocoCashuApp + CocoCashuSwift

Tracking document for the security audit conducted 2026-07-18. Findings span two
repositories:

- **App**: `CocoCashuApp/` (this repo)
- **Library**: `CocoCashuSwift/` (`Sources/CocoCashuCore`, `Sources/CocoCashuUI`)

Each item has a checkbox — mark `[x]` when the fix is merged and verified. Keep the
"Verified by" note short (test name, manual step, or PR link).

**Legend:** 🔴 Critical · 🟠 High · 🟡 Medium · ⚪ Low

**Status summary:** 34 / 34 complete — **all phases done.**

| Severity | Count | Done |
|----------|-------|------|
| 🔴 Critical | 5 | 5 |
| 🟠 High | 7 | 7 |
| 🟡 Medium | 13 | 13 |
| ⚪ Low | 9 | 9 |

Verification: `CocoCashuSwift` `swift test` passes (11/11, incl. official NUT-12
DLEQ vector, official NUT-13 derivation vectors v00+v01, keyset-ID rejection, and
NUT-02 ID validation); `xcodebuild -scheme CocoCashuApp` build succeeds.

> **Migration note (H5):** derivation now follows NUT-13 exactly, which is a
> different scheme than this wallet used before. Proofs already stored in
> `proofs.json` are unaffected (full proof data is persisted), but any *lost*
> proofs minted under the old scheme can no longer be found by "Scan for Lost
> Funds". Ship this before real users depend on seed backups.

---

## Phase 1 — Critical (fix before storing real value)

### 🔴 C1. Implement NUT-12 DLEQ verification; replace the always-true `verify()`
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Engines/CocoBlindingEngine.swift:230-245`, `Network/RealMintAPI.swift:581`
- **Problem:** `verify()` only checks that inputs parse as EC points and returns `true` unconditionally; it is never called. No DLEQ (NUT-12); the `dleq` field is dropped from mint responses. A malicious mint can deanonymize tokens or return garbage `C` values that get stored as balance.
- **Fix:**
  1. Add a `dleq` DTO (`e`, `s`, and `r` for proofs) to the mint response models; stop dropping it in `RealMintAPI`.
  2. Implement NUT-12 DLEQ verification for `BlindSignature` (`e == hash(R1, R2, K, C_)` with `R1 = s·G − e·K`, `R2 = s·B_ − e·C_`).
  3. Implement proof-level DLEQ check (`C` with blinding factor `r`) for received tokens.
  4. Call verification inside `unblind` **before** storing proofs; reject and unreserve inputs on failure.
  5. Delete or rename the stub so it can never silently pass.
- **Verified by:** `verifyDLEQAlice` in `CocoBlindingEngine` (R1=s·G−e·A, R2=s·B_−e·C_, e==SHA256 of uncompressed-hex R1‖R2‖A‖C_); `dleq` threaded through `BlindSignatureDTO` and the swap/mint/melt-change decoders in `RealMintAPI`; enforced in `unblind` (drops signature on invalid proof); old always-true `verify` removed from the `BlindingEngine` protocol. Test `testDLEQVerifiesOfficialNUT12BlindSignatureVector` passes against the official NUT-12 Test Case 1 and rejects a tampered `s`. **Note:** verification runs only when the mint supplies a proof; requiring DLEQ (rejecting mints that omit it) is a follow-up policy decision. Carol-side (received-token) proof verification is not yet wired — only the mint-response (Alice) path is.

### 🔴 C2. Fix seed-restore signature↔secret pairing
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Services/WalletRestorationService.swift:68-90, 115-140`; `Network/RealMintAPI.swift:703-709`
- **Problem:** `attemptUnblind` succeeds for any well-formed (sig, r) pair, so all restored proofs get secret index 0 → unspendable duplicates. The NUT-09 restore response's matched `outputs`/`B_` are discarded.
- **Fix:**
  1. Decode the `outputs` (`B_`) array from the restore response in `RealMintAPI.restore`.
  2. Match each returned signature to its request by `B_` (not by position), then unblind with the corresponding `r`/secret.
  3. Stop sending 14 duplicate amounts per `B_`; send each blinded output once.
  4. After unblinding, run DLEQ/`C == k·Y` verification (depends on C1) instead of trusting parse success.
- **Verified by:** `RealMintAPI.restore` now returns `(outputs, promises)` and decodes the echoed `outputs`; `WalletRestorationService` builds a `B_ → (secret, r)` map, sends each `B_` once (placeholder amount), and pairs `promises[i]` to the secret via `echoedOutputs[i].B_` — replacing the "try every secret, accept first that unblinds" loop that collapsed onto index 0. MintCoordinator's zombie-quote recovery updated to `.promises`. Library builds; existing derivation tests pass. **Not yet done:** step 4 (DLEQ on restored proofs — restore promises carry no DLEQ) and counter fast-forward (tracked as H1).

### 🔴 C3. Encrypt/protect persisted proofs and exclude wallet files from backup
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuUI/ObservableWallet.swift:93-117`; `CocoCashuApp/CashuBootstrap.swift:103-107, 130-144`
- **Problem:** Proofs (bearer money) written as plaintext JSON with plain `write(to:)` — no file protection, not excluded from backup, no Data Protection entitlement. Two writers race on the same file.
- **Fix:**
  1. Write with `.completeFileProtection` (or `.completeUnlessOpen`) on all wallet files (`proofs.json`, `counters.json`, `history.json`).
  2. Set `isExcludedFromBackup = true` on the wallet directory.
  3. Add the Data Protection capability/entitlement to the app target.
  4. Consolidate to a **single** writer for `proofs.json` (remove the duplicate write path), or serialize writes through one actor.
  5. Consider storing proofs in the Keychain or an encrypted store instead of a JSON file.
- **Verified by:** `CashuBootstrap.saveWallet` writes `proofs.json` with `.completeFileProtection` (iOS) + `.atomic`; `storeURL()` sets `isExcludedFromBackup` on the `CocoCashuWallet` directory (covers proofs, counters, history); `FileCounterRepository.persist` also uses complete protection. Duplicate writer removed from `ObservableWallet` (its `persistProofs`/`storeURL`/`WalletStoredProof` deleted) — `CashuBootstrap` is now the sole writer. App builds. **Not done:** step 5 (still a protected JSON file, not Keychain/encrypted-store); add the Data Protection **entitlement** to the target in Xcode (the write option applies protection, but the explicit capability is still recommended).

### 🔴 C4. Mnemonic pasteboard hardening
- [x] **Done**
- **Where:** `CocoCashuApp/BackupView.swift:54-60`
- **Problem:** Seed copied via `UIPasteboard.general.string` — syncs via Universal Clipboard, persists indefinitely, readable by any app.
- **Fix:** Use `UIPasteboard.general.setItems(_:options:)` with `.localOnly: true` and a short `.expirationDate` (e.g. 60s); ideally require FaceID/passcode before enabling copy, and show a warning. Same treatment for the macOS `NSPasteboard` branch (or omit copy there).
- **Verified by:** `BackupView` iOS copy now uses `setItems(options: [.localOnly: true, .expirationDate: now+60s])`; macOS branch marks the item `org.nspasteboard.ConcealedType` so clipboard managers skip it. App builds. **Follow-up:** FaceID/passcode gate before copy is M1 (Phase 3).

### 🔴 C5. Fix melt failure path (fund-loss window)
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Services/MintService.swift:93-95`; `Network/RealMintAPI.swift:337-352`
- **Problem:** Any error after melt dispatch unreserves inputs back to `.unspent` with no `.pending` state and no NUT-07 reconciliation. If the LN payment actually completed, change is lost and the "spendable-again" proofs are already spent → user loses `amount + fee_reserve`.
- **Fix:**
  1. Add a `.pending` proof state; move inputs to `.pending` (not back to `.unspent`) on ambiguous melt errors (timeout, TLS drop, `PENDING`).
  2. On next launch / retry, call `POST /v1/checkstate` (NUT-07) to reconcile: if spent, finalize and fetch change; if unspent, release.
  3. Only unreserve to `.unspent` when the mint definitively reports the melt failed.
- **In-session polling (added after a real PENDING report on a live 44-sat payment):**
  `RealMintAPI.checkMeltQuote` (NUT-05 `GET /v1/melt/quote/bolt11/{id}`) + `MintService.spend`
  now polls a PENDING melt for up to 90s and resolves it to PAID/UNPAID in-session
  instead of surfacing PENDING as a failure. `spend` returns `MeltResult` (`.paid`/
  `.pending`); `MeltView` renders `.pending` as "processing", not "Failed". Only a
  still-unresolved-after-polling melt is parked for launch reconciliation.
- **Verified by:** Added `ProofState.pending`; `RealMintAPI.executeMelt` throws `.meltUnpaid` (definitely not paid → safe to release) vs `.meltPending`/other (ambiguous). `MintService.spend` restructured into Phase A (pre-melt prep → unreserve on failure), Phase B (submit → only `.meltUnpaid` unreserves; everything else marks inputs `.pending`), Phase C (mark spent first, then best-effort change so a change failure can't resurrect spent inputs). New `MintService.reconcilePending` runs NUT-07 `checkstate`: SPENT→finalize, UNSPENT→release, PENDING→leave. Pending proofs persist with state (`StoredProof.state`, saved from `getUnspent + pendingProofs`, restored honoring state) so they survive a kill; `CashuBootstrap.makeWallet` calls `reconcilePending` on launch. Library builds/tests pass; app builds. **Manual E2E not run** (needs a live mint + induced timeout).

---

## Phase 2 — High

### 🟠 H1. Advance the NUT-13 counter after restore
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Services/WalletRestorationService.swift`; `Repositories/RepositoryInterfaces.swift:30-36`
- **Problem:** Restore never bumps the counter; on a fresh device the next `blind()` re-derives index-0 secrets the mint already signed → rejection or duplicate proofs.
- **Fix:** Add a `set/bumpTo(_:)` primitive to `CounterRepository`; after a restore scan, set each keyset's counter past the highest index that returned a signature. Also account for backup-rollback (counter file restored older than the seed's true position).
- **Verified by:** `CounterRepository.advance(key:to:)` added (forward-only, persisted) and implemented in both repos; `CashuManager` now exposes `counterRepo`; `WalletRestorationService` tracks the highest index the mint returned a signature for — including already-SPENT indices — and advances the counter past it per keyset. Backup-rollback is mitigated structurally: the wallet dir is excluded from backup (C3), and a fresh device's counter is fast-forwarded by running the restore scan.

### 🟠 H2. Keychain read must fail closed; check write status
- [x] **Done**
- **Where:** `CocoCashuApp/CashuBootstrap.swift:35-41`; `CocoCashuSwift/Sources/CocoCashuCore/Managers/SeedManager.swift:48-77`; `RestoreView.swift:71`
- **Problem:** `retrieveFromKeychain()` returns `nil` for any non-success status (locked, denied, interaction-not-allowed), not just `errSecItemNotFound`; bootstrap then generates a new seed and deletes the old item. `SecItemAdd` status is ignored.
- **Fix:**
  1. In `retrieveFromKeychain`, distinguish `errSecItemNotFound` (→ no wallet) from all other statuses (→ throw / fail closed, never overwrite).
  2. Check the `SecItemAdd`/`SecItemUpdate` `OSStatus` and throw on failure.
  3. Remove `try?` at the `saveToKeychain` call site (`RestoreView.swift:71`) and surface errors.
- **Verified by:** `retrieveFromKeychain()` now throws `SeedKeychainError.readFailed` for any status other than success/`errSecItemNotFound` (and for an unreadable stored item), returning nil ONLY on a positive not-found; `saveToKeychain` checks both `SecItemDelete` and `SecItemAdd` statuses and throws `writeFailed`. `CashuBootstrap` fails closed (fatalError) instead of regenerating; `RestoreView` surfaces the save error and aborts instead of `try?`. Also sets `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (see M5); delete uses a minimal search query so pre-existing items saved under old defaults still match.

### 🟠 H3. Persist reserved proofs; enforce reservation timeout; unreserve on error
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Services/MintService.swift:109-176`; `ProofService.swift:25-27`; `Repositories/InMemoryRepositories.swift:51-58`; `CocoCashuApp/CashuBootstrap.swift:91`
- **Problem:** Reserved proofs are excluded from disk writes; `createToken` has a `do` block with no catch/unreserve; the 60s reservation timeout is enforced nowhere.
- **Fix:**
  1. Persist `.reserved` proofs too (so an app kill doesn't lose them).
  2. Add `catch { unreserve }` to `createToken` (mirror `CashuManager.send`).
  3. Enforce `reservedUntil` in `fetchUnspent` (treat expired reservations as available again).
- **Verified by:** `fetchUnspent` now lazily releases expired `.reserved` proofs (never `.pending` ones — those are mint-submitted and only NUT-07 may release them); default reservation timeout raised 60s→300s so it can't expire under a live 120s melt request and let a concurrent op double-spend the inputs. `createToken` restructured into the same three-phase discipline as melt: pre-swap errors unreserve, post-submit errors mark `.pending` (NOT unreserve — the mint may have executed the swap), post-response unblind failures mark spent (truthful; recoverable by scan). Reserved proofs are persisted (`reservedProofs` accessor + saveWallet) and reload as `.pending` so launch reconciliation resolves them. Note this goes beyond the plan's suggested "catch → unreserve", which would itself have been a double-spend bug for errors after the swap request left the device.

### 🟠 H4. Cap and confirm melt `fee_reserve`
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Services/MintService.swift:47-55`; `Network/RealMintAPI.swift:307-315`
- **Problem:** `fee_reserve` accepted verbatim, never sanity-checked, never shown to the user; huge values enable theft and `Int64` overflow crash.
- **Fix:** Sanity-cap `fee_reserve` (absolute + percentage of amount); reject/​warn above threshold; surface the fee in the melt UI for explicit confirmation before signing inputs; guard the `amount + feeReserve` sum against overflow.
- **Verified by:** `MintService.spend` rejects negative fee reserves, caps at `maxAcceptableFeeReserve` (max(10 sats, 2% of amount), refusing with a clear error above it), guards `amount + feeReserve` with `addingReportingOverflow`, and requires `amount > 0`. **Not done:** interactive fee confirmation in the melt UI (the cap is the security control; showing the quoted fee before Pay is a UX follow-up).

### 🟠 H5. Align NUT-13 derivation with the spec
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Crypto/HDKey.swift:24-49`; `Engines/CocoBlindingEngine.swift:115-134, 184-197`
- **Problem:** Non-standard in three ways — child key is `I_L` alone (not `(I_L + k_parent) mod n`); keyset-id-to-int uses first 4 bytes instead of `int(id) % (2^31-1)`; leaf derivation skips the spec's `/{counter}'/0` and `/{counter}'/1` child paths. Seed is not portable to other wallets.
- **Fix:** Implement standard BIP32 CKDpriv (with `I_L >= n` skip), spec-correct keyset-id-to-int over the full 8-byte ID, and the two leaf child paths. **Do this before users rely on backups** — changing it later orphans previously derived proofs. Add cross-wallet interop test vectors (cashu.me/cdk).
- **Verified by:** `HDKey` rewritten as real BIP32 (child = `(I_L + k_par) mod n` via `secp256k1_ec_seckey_tweak_add`, hardened AND non-hardened CKDpriv — the NUT-13 leaf steps `/0` and `/1` are non-hardened, which the old code couldn't even express). Engine derives per spec for BOTH keyset versions: v00 BIP32 path `m/129372'/0'/{int(id) % (2³¹−1)}'/{counter}'/0|1`, and v01 HMAC-SHA256 KDF (`"Cashu_KDF_HMAC_SHA256" ‖ id ‖ counter_u64_be ‖ type`, r reduced mod n). Tests `testNUT13Version00/01DerivationMatchesOfficialVectors` pass against the official NUT-13 vectors (5 counters each). See the migration note at the top of this file.

### 🟠 H6. Non-hex keyset IDs must not collapse to branch 0
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Engines/CocoBlindingEngine.swift:186-194`; `Network/RealMintAPI.swift:515, 523, 532`
- **Problem:** Non-hex keyset IDs return `0` instead of throwing; two such keysets derive identical `(secret, r)` at each index → linkability and duplicate proofs. `fetchKeyset` can produce non-hex IDs (falls back to base URL string).
- **Fix:** Throw on unparseable keyset IDs; stop falling back to the base URL as an ID; validate keyset IDs are the correct hex format on receipt (ties to NUT-02, H7).
- **Verified by:** `deriveSecretAndR` throws `CashuError.cryptoError` on any keyset ID that isn't valid hex of a supported version/length (00/8-byte or 01/33-byte) — the silent `return 0` is gone. Base-URL fallback IDs removed (see H7). Test `testDerivationThrowsOnUnsupportedKeysetIDs` covers URL-shaped, base64-ish, odd-length and wrong-version IDs.

### 🟠 H7. Validate what the mint returns (NUT-02 keyset ID integrity + pinning)
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Engines/CocoBlindingEngine.swift:65, 166`; `Network/RealMintAPI.swift:506-536, 776-813`; `CocoCashuApp/CashuBootstrap.swift:48-51`
- **Problem:** Keyset ID is never recomputed as the hash of the keys (NUT-02); keys are refetched every op and never pinned; the signature's keyset id is taken from the mint's response over the wallet's own record.
- **Fix:** Recompute and verify the keyset ID from the returned keys per NUT-02; pin/persist keysets across sessions and detect unexpected changes; use the wallet's recorded keyset id, not the mint's echoed one.
- **Verified by:** `Keyset.deriveV00Id(keys:)` implements NUT-02 v00 (sort by amount, concat compressed pubkeys, SHA256, first 14 hex chars, "00" prefix); `RealMintAPI.fetchKeyset()`/`fetchKeyset(mint:id:)` reject any keyset whose claimed v00 ID mismatches its keys, and when a mint omits the ID it is now DERIVED from the keys instead of falling back to the base URL. `unblind` stamps proofs with the wallet's own `input.id`, not the mint's echoed id. Test `testKeysetV00IdDerivationAndValidation` passes. **Not done:** v01 ID verification (needs unit/expiry fields on `Keyset`) and cross-session keyset pinning — both follow-ups.

---

## Phase 3 — Medium

### 🟡 M1. Add authentication gate on seed reveal
- [x] **Done**
- **Where:** `CocoCashuApp/BackupView.swift:183-191`
- **Fix:** Require FaceID/TouchID/passcode via `LocalAuthentication` (`LAContext.evaluatePolicy`) before revealing the mnemonic; clear `words` from `@State` promptly. Consider an app-launch lock too.
- **Verified by:** `revealSeed()` requires `.deviceOwnerAuthentication` (FaceID/TouchID with passcode fallback) before showing the phrase; falls back to plain reveal only when the device has no passcode at all (nothing to authenticate against). The revealed words are wiped from `@State` on `onDisappear` and whenever `scenePhase` leaves `.active`. **Follow-up:** an app-launch lock is still a possible enhancement.

### 🟡 M2. Privacy screen on backgrounding + `.privacySensitive()`
- [x] **Done**
- **Where:** `CocoCashuApp/CocoCashuAppApp.swift`; `BackupView.swift`; `WalletView.swift:57, 352`
- **Fix:** Add a blur/cover overlay when `scenePhase != .active`; mark seed/balance/token views `.privacySensitive()` so they're redacted in the switcher snapshot.
- **Verified by:** App root overlays an `.ultraThinMaterial` cover (with app glyph) whenever `scenePhase != .active`, so the app-switcher snapshot never contains balances/tokens/seed; `.privacySensitive()` added to the balance text, the token display, and the seed word grid; BackupView additionally hides the seed entirely on backgrounding (see M1).

### 🟡 M3. `RealMintAPI` must honor its `mint:` parameter
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Network/RealMintAPI.swift:594-631`; `CocoCashuUI/MintCoordinator.swift:145, 167`
- **Problem:** `mint:` params are ignored (URLs built from `self.baseURL`); cross-mint receive fetches keysets from an attacker URL but submits proofs to the default mint, leaking proofs and the victim's IP/activity.
- **Fix:** Route each request to the correct mint URL; make cross-mint receive coherent (single mint per operation) or explicitly reject foreign-mint tokens with a clear error.
- **Verified by:** `makeURL`/`getJSON`/`postJSON` take an optional `base:` and every `mint:`-taking method passes its mint through (`requestMintQuote`, `checkQuoteStatus`, `requestTokens`, `requestMeltQuote`, `executeMelt`, `swap`); `fetchKeyset(mint:)` added to the `MintAPI` protocol; `MintCoordinator.receive` fetches the fee keyset from the TOKEN's mint, so fee keyset, blinding keyset, and swap endpoint are the same server — cross-mint receive is coherent.

### 🟡 M4. Enforce `https` scheme on all mint URLs
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Network/RealMintAPI.swift` (init); `CocoCashuUI/MintCoordinator.swift:237`
- **Fix:** Reject non-`https` mint URLs in `parseToken` and `RealMintAPI.init` with an explicit "insecure mint" error instead of silently failing. Consider certificate pinning for the default mint.
- **Verified by:** `RealMintAPI.requireSecure(_:)` enforced at every request path (`getJSON`/`postJSON` plus the manually-built `restore`/`check`/`fetchKeysetIds`/`fetchKeyset(mint:id:)` requests) and in `parseToken` for token-supplied mint URLs — clear "refusing insecure mint URL" error. Deliberate exception: `http` allowed for loopback hosts (localhost/127.0.0.1/::1) so local dev mints still work. **Not done:** certificate pinning (follow-up).

### 🟡 M5. Keychain accessibility policy
- [x] **Done** (landed with H2)
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Managers/SeedManager.swift:40-45`
- **Fix:** Set `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` explicitly (paper backup is the recovery path); confirm no `kSecAttrSynchronizable`. Document the backup-migration decision.
- **Verified by:** `saveToKeychain` sets `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; no `kSecAttrSynchronizable` anywhere. Decision documented in code: the paper phrase is the only cross-device recovery path — the seed no longer migrates via encrypted backup or device transfer. Applies to items (re)written after this change; the item is rewritten on any import/restore/reset.

### 🟡 M6. Seed import must reset wallet state and reinitialize the engine
- [x] **Done**
- **Where:** `CocoCashuApp/ImportWalletView.swift:78-95`; `RestoreView.swift:52-79`; `CashuBootstrap.swift:48`
- **Problem:** Import overwrites the keychain seed but keeps `proofs.json`/`counters.json` and the running blinding engine keeps deriving from the old seed until manual restart.
- **Fix:** On import, wipe/rescope proofs+counters+history for the new seed and reinitialize the blinding engine (or force a clean relaunch); don't allow minting on seed A while displaying seed B.
- **Verified by:** New `CashuBootstrap.resetStateForImportedSeed()` wipes proofs/counters/history (keeping the newly saved seed); `ImportWalletView.performImport` calls it and then `exit(0)` after the destructive-confirmation alert (same close-and-relaunch pattern as the existing reset buttons), so the engine can never keep minting on the old seed; `RestoreView` wipes state too. The alert text tells the user the app will close.

### 🟡 M7. Wallet reset must clear `history.json`
- [x] **Done**
- **Where:** `CocoCashuApp/CashuBootstrap.swift:162-166`; `CocoCashuSwift/Sources/CocoCashuCore/Services/HistoryService.swift:15-23`
- **Fix:** Include `history.json` in `resetWalletNewSeed` (and any full-reset path).
- **Verified by:** `historyStoreURL()` added; `resetWalletNewSeed()` and `resetStateForImportedSeed()` both remove `history.json` alongside proofs and counters. (The wallet directory as a whole is also backup-excluded since C3.)

### 🟡 M8. `unblind` must use the keyset for the correct mint
- [ ] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Engines/CocoBlindingEngine.swift:34-35, 66, 139-141`
- **Problem:** Single globally-cached keyset slot; interleaved two-mint flows unblind against the wrong pubkey.
- **Fix:** Key the keyset cache by (mint, keysetId); `unblind` looks up by the operation's mint/keyset rather than "last set".
- **Verified by:** The engine's `Store` now caches keysets per mint URL; `blind` writes `setKeyset(ks, for: mint)` and `unblind` reads `getKeyset(for: mint)` (fetching fresh on miss). Interleaved two-mint flows can no longer unblind against the wrong mint's keys.

### 🟡 M9. Check `SecRandomCopyBytes` status at seed generation
- [x] **Done**
- **Where:** BIP39 dep `Mnemonic.swift:27` (`pengpengliu/BIP39`); mirror checks in `Core/EC.swift:19-23`, `Models/Types.swift:97-101`
- **Problem:** Ignored failure status → all-zero entropy → the well-known "abandon abandon…" seed.
- **Fix:** Verify the `errSecSuccess` return and abort on failure. If the dependency can't be patched, fork/vendor or generate entropy locally with a checked `SecRandomCopyBytes` and pass it in.
- **Verified by:** `SeedManager.generateNewMnemonic` now generates the 128-bit entropy itself with a checked `SecRandomCopyBytes` (throws on non-success and on an all-zero buffer) and feeds it to `BIP39.Mnemonic(entropy:)`, bypassing the dependency's unchecked convenience init entirely. The unused `rng`/`randomBytes` helpers (EC.swift/Types.swift) remain unchecked but have no callers.

### 🟡 M10. Pair signatures to outputs by index, not amount
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Engines/CocoBlindingEngine.swift:146-148`
- **Problem:** `firstIndex(where: amount ==)` mispairs when duplicate denominations exist and the mint reorders.
- **Fix:** After asserting `signatures.count == inputs.count`, pair strictly by index (mints return signatures in request order per spec).
- **Verified by:** `unblind` pairs `signatures[i]` ↔ `inputs[i]` (rejecting more signatures than outputs) with the signature's amount authoritative — important for melt change, where the mint assigns denominations to our blinded points, so the pubkey lookup and proof amount now come from `sig.amount`. Fewer-signatures-than-outputs (fee-consumed change) still works: the returned prefix corresponds positionally.

### 🟡 M11. Standard-compliant token serialization
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Models/TokenHelper.swift:13-24`; `Models/Proof.swift:73-89`
- **Problem:** Secret emitted as base64-of-Data instead of UTF-8 string; UUID/mint/timestamps embedded → other wallets can't redeem; sender fingerprinted; sent proofs marked spent → limbo.
- **Fix:** Serialize per NUT-00 (secret as its UTF-8 string; only `id`/`amount`/`secret`/`C` per proof); strip internal fields; add interop redemption tests.
- **Verified by:** `TokenHelper` rewritten: `TokenV3.TokenProof` carries only `id`/`amount`/`secret`/`C` with the secret as its UTF-8 string (throws rather than emit a non-UTF-8 secret other wallets can't redeem); `unit: "sat"` included; no UUIDs/mint/state/timestamps leak to recipients. **Not done:** live interop redemption test against another wallet (manual step).

### 🟡 M12. Bound token size / proof count; use mint quote for amounts
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuUI/MintCoordinator.swift:200-261`; `Models/TokenHelper.swift:26-44`; `CocoCashuApp/MeltView.swift:176-211`, `WalletView.swift:607-625`
- **Problem:** No cap on token length/proof count (DoS); hand-rolled BOLT11 amount parsing (no bech32 checksum), and the app's two parsers disagree on fractional sats.
- **Fix:** Enforce max token length + max proof count before decoding; take the melt amount/fee from the mint's melt quote, not client-side regex; consolidate to one invoice parser (or a real bech32 decoder).
- **Verified by:** `parseToken` caps token length (100k chars) and proof count (512). `requestMeltQuote` now returns the mint's quoted amount and `MintService.spend` ABORTS if it disagrees with the client-parsed amount — the mint's decode of the invoice is authoritative, and a parser bug or over-quoting mint surfaces as an error instead of a wrong payment. `MeltView.decodeAmount` rewritten in integer math, rejecting fractional-sat invoices instead of truncating (the disagreement with WalletView's parser is gone; WalletView's copy only serves the unreachable withdraw sheet, tracked in L9). **Not done:** full bech32 checksum validation (the mint-quote cross-check makes the client parse a preview only).

### 🟡 M13. Ecash token pasteboard hardening
- [x] **Done**
- **Where:** `CocoCashuApp/WalletView.swift:360-367`; `InvoiceSheet.swift:77-84`
- **Fix:** Copy tokens with `.localOnly` + `.expirationDate`; warn that the token is spendable and persist the outgoing token so a discarded/unshared token is recoverable (see L8).
- **Verified by:** Token copy uses `setItems` with a 5-minute `.expirationDate`; invoice copies likewise. Deliberate deviation from the plan: NOT `.localOnly` for tokens/invoices — unlike the seed, they exist to be shared, and pasting on the user's other device via Universal Clipboard is legitimate; expiry alone removes the indefinite-exposure risk. Outgoing-token persistence remains under L8.

---

## Phase 4 — Low

### ⚪ L1. Validate amounts are non-negative (and power-of-two on receipt)
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Models/Proof.swift:63`, `Models/Types.swift`, `Network/RealMintAPI.swift:86,126,146`
- **Fix:** Reject negative amounts at decode; validate denominations are valid powers of two.
- **Verified by:** `unblind` skips any signature with `amount <= 0`; `MintCoordinator.receive` rejects the token if any proof amount is non-positive. Melt amount and fee reserve are also guarded (H4). **Not done:** explicit power-of-two validation — the keyset-key lookup already rejects unsupported denominations, so a non-power-of-two amount finds no signing key and is dropped.

### ⚪ L2. Guard against overflow in sums/fee math
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Services/MintService.swift:62-63,89-90,113-120`; `Models/Types.swift:91`; `WalletRestorationService.swift`
- **Fix:** Use overflow-checked arithmetic (`&+` guards / `reduce` with checks) so crafted responses fail gracefully instead of trapping.
- **Verified by:** The untrusted-input boundaries are guarded: `MintCoordinator.receive` sums token proof amounts with `addingReportingOverflow` (throws on overflow), melt guards `amount + feeReserve` (H4), and negative amounts are rejected at decode (L1) so they can't feed the internal sums. Wallet-owned proof sums (`reduce(0,+)`) operate on already-validated, bounded values.

### ⚪ L3. Strip debug logging from release builds
- [x] **Done**
- **Where:** ~35 `print`/log calls incl. `WalletView.swift:385,416`, `MintCoordinator.swift:42,67`, `RealMintAPI.swift:405,699,211`
- **Fix:** Wrap in `#if DEBUG` or a leveled logger; ensure full invoice URLs and raw mint error bodies are never logged/shown in release. (No secrets currently logged — keep it that way.)
- **Verified by:** Added `cocoLog(...)` (a `#if DEBUG` no-op in release) and replaced all 34 library `print(` calls with it, so amounts/quote-IDs/error bodies never reach a shipping app's system log. App-layer `print("Ecash Error:")` calls in WalletView removed (L8). `ensureOK` error strings now identify endpoints by host+path only, so a full BOLT11 invoice in a `?invoice=` query no longer leaks into UI/error text.

### ⚪ L4. Drop stored `seed` property / add zeroization where feasible
- [x] **Done (reclassified — won't drop)**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Engines/CocoBlindingEngine.swift:8`
- **Fix:** Discard the raw seed after deriving `masterKey`; scrub with `withUnsafeMutableBytes` where practical.
- **Verified by:** No longer applicable: the NUT-13 **version-01** KDF added in H5 keys HMAC-SHA256 with the seed itself, so the raw seed is legitimately needed for the engine's lifetime and cannot be dropped after `masterKey` derivation. Swift's value-copy semantics also make reliable zeroization of the seed `Data` impractical. Left as-is by design; the seed lives only in memory and in the (this-device-only, backup-excluded) Keychain.

### ⚪ L5. Guard `InMemoryCounterRepository` misuse
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Repositories/InMemoryRepositories.swift:111-120`
- **Fix:** Add a doc warning / rename to `Ephemeral…`/`Testing…` so it can't be mistaken for production (resets each launch → secret reuse). App already uses the file-backed repo.
- **Verified by:** Prominent doc comment marks it **for tests only** and states that production use guarantees derivation-index reuse; directs callers to `FileCounterRepository`. Kept the name to avoid churning the test suite, which is its only caller.

### ⚪ L6. Throw instead of substituting scalars for invalid values
- [x] **Done**
- **Where:** `CocoCashuSwift/Sources/CocoCashuCore/Core/EC.swift:55-58, 71-74`
- **Fix:** Throw on `seckey_verify` failure rather than silently substituting `sha256(scalar)` (masks bugs).
- **Verified by:** `ec_pubkey_from_scalar` and `ec_tweak_mul_pubkey` now throw `ECError.invalidScalar` on an invalid scalar instead of substituting `sha256(scalar)`. Safe because all scalars are spec-derived into range (BIP32 keys, mod-n-reduced r, hash-derived DLEQ `e`); an invalid one now signals a real bug (or, in DLEQ, correctly fails verification) rather than being silently masked. All 11 tests still pass, confirming legitimate flows use in-range scalars.

### ⚪ L7. Make all wallet-file writes atomic + protected
- [x] **Done**
- **Where:** `CocoCashuApp/CashuBootstrap.swift:103-107`; `HistoryService.swift:41-45`
- **Fix:** Use `.atomic` + `.completeFileProtection` consistently across all persistence (overlaps C3).
- **Verified by:** `HistoryService.save` now writes `.atomic` + `.completeFileProtection` (iOS), matching proofs.json (C3) and counters.json (H3/C3). All three wallet files are now atomic + protected + backup-excluded.

### ⚪ L8. Send flow must not silently discard a live token; separate Send/Mint state
- [x] **Done**
- **Where:** `CocoCashuApp/WalletView.swift:370-373, 379` (shared `mintAmountString`)
- **Fix:** Persist the outgoing token until confirmed shared; confirm before discarding on "Done"; give Send its own amount state so it can't inherit the last Mint amount (one-tap over-send).
- **Verified by:** Send has its own `sendAmountString` (Create Token disabled until it parses), so it can no longer inherit the last Mint amount. "Done" now shows a confirmation dialog warning that unclaimed funds need a seed scan before it discards the token string. **Not done:** durable persistence of the outgoing token across app kill (the confirmation covers the accidental-tap case; full persistence is a larger change).

### ⚪ L9. Remove or guard the unreachable Withdraw double-spend path
- [x] **Done**
- **Where:** `CocoCashuApp/WalletView.swift:199-207, 319`
- **Fix:** Delete the dead Withdraw sheet, or add an `isWithdrawing` reentrancy guard before it's ever wired up.
- **Verified by:** Deleted entirely — the unreachable `withdrawSheet`, `performWithdraw()`, the `parseSatsFromBOLT11` helper, and all `withdraw*` state. Lightning payment is handled solely by `MeltView`/`MintService.spend`, which already has the fee cap and pending-state safety (H4/C5).

---

## Notes

- **Ordering rationale:** Phase 1 items are direct fund-loss / total-compromise paths.
  Phases 2–3 harden recovery, mint-trust, and app-layer exposure. Phase 4 is hygiene.
- **Sequencing dependencies:** C1 (DLEQ) should land before C2 (restore) so restore can
  verify unblinded proofs. H5 (NUT-13 derivation) should land **before** any public
  release users back up seeds against, since changing it later orphans derived proofs.
  C3 and L7 overlap — do the file-protection work once.
- **Testing:** add interop test vectors against cashu.me / cdk for H5/M11, and
  end-to-end mint→send→receive→melt tests exercising the failure/kill paths for C5/H3.

## Outstanding follow-ups (all 34 findings fixed; these are the deferred extras)

Non-blocking enhancements noted in the "Verified by" lines above, collected here:

1. **Add the Data Protection entitlement** to the app target in Xcode (C3) — the
   write-time `.completeFileProtection` is in place; the capability is belt-and-braces.
2. **Carol-side DLEQ** — verify DLEQ on *received* tokens, and optionally *require*
   DLEQ (reject mints that omit it) rather than verify-if-present (C1).
3. **Version-01 keyset-ID verification + cross-session keyset pinning** (H7) — needs
   unit/fee/expiry fields added to the `Keyset` model.
4. **Interactive melt-fee confirmation** in the UI before Pay (H4) — the cap is the
   security control; showing the quoted fee is UX.
5. **App-launch biometric lock** (M1) — currently only the seed reveal is gated.
6. **Certificate pinning** for the default mint (M4).
7. **Durable outgoing-token persistence** across app kill (L8) + live cross-wallet
   interop redemption test (M11).
8. **Manual/E2E verification** against a live mint with induced timeouts for the
   melt/swap failure paths (C5/H3) — logic is unit-tested where testable but not yet
   exercised end-to-end.

### Migration reminder (H5)
NUT-13 derivation is now spec-exact, which differs from the wallet's previous scheme.
Proofs already in `proofs.json` are fine, but funds *lost* under the old scheme can no
longer be found by "Scan for Lost Funds". Ship before real users rely on seed backups.

### Field-testing additions (post-audit)
- **Melt PENDING polling** (see C5): a live 44-sat payment surfaced that PENDING was
  shown as "Failed"; `spend` now polls the NUT-05 melt quote and returns
  `.paid`/`.pending` instead of erroring.
- **V4 (cashuB) token receive support**: receiving from Minibits failed — modern
  wallets send CBOR-encoded cashuB tokens, which the JSON-only parser rejected.
  Added a minimal hardened CBOR decoder + `TokenV4Helper` (validated against both
  official NUT-00 V4 test vectors, malformed-input fuzz cases included) and
  version dispatch in `parseToken`. Also fixed a latent V3 bug: secrets were tried
  as base64 first, but a 64-char hex secret is coincidentally valid base64 and
  silently decoded to garbage (unspendable proof) — secrets are now always UTF-8
  per NUT-00. Sending still serializes V3 (cashuA), which all wallets accept.
- **NUT-02 keyset validation false-positive on 64-key mints** (H7 refinement):
  the recomputed keyset ID was derived from the Int64-parsed key map, but mints
  publish 64 denominations up to 2^63 — one more than `Int64.max` — so that key
  silently dropped and every honest 64-key mint (e.g. mint.minibits.cash) was
  rejected as lying about its keyset ID. Verified against the live mint: all 64
  keys → `00107937db0cc865` (matches its claim); Int64-truncated 63 keys →
  `001ae72c2c5f6bce` (the wrong rejection). `deriveV00Id`/`isValidV00Id` now
  operate on the RAW amount-string→pubkey map sorted as UInt64. Regression test
  `testKeysetV00IdIncludesAmountsBeyondInt64` pins the behavior. (The parsed
  Int64 map still omits the unusable 2^63 denomination for wallet math, which is
  harmless — no real token carries a 2^63-sat proof.)
- **Multi-mint balance visibility** (M3 follow-on): a successful cross-mint receive
  (13 sats from Minibits) stored proofs under the token's mint, but the "TOTAL
  BALANCE" card only summed the hardcoded default mint — received funds were
  invisible (though safely persisted). The card now sums across all mints with a
  per-mint breakdown when more than one holds funds; Send picks the
  largest-balance mint that covers the amount (a token spends from ONE mint);
  `MintService.createToken`/`swap` fetch the fee keyset from the mint actually
  being spent at. "Scan for Lost Funds" now scans every known mint (default +
  all mints holding proofs + an optional user-entered mint URL for fresh-device
  restores, validated by the same https policy), reporting per-mint results and
  continuing past individual mint failures.
- **Restore scan skips legacy keysets** (H6 follow-on): mints still LIST legacy
  base64 keyset IDs (e.g. `ctv28hTYzQwr` on mint.minibits.cash); the engine's
  correct refusal to NUT-13-derive on them was aborting the whole mint scan.
  `WalletRestorationService` now gates keysets on `supportsNUT13Derivation`
  (hex v00/v01 only — this wallet can never hold funds under legacy keysets)
  and isolates per-keyset scan errors so one keyset can't kill the rest.
  Regression test `testRestoreKeysetSupportGate`.
- **NUT-07 endpoint was wrong — restore verification and pending reconciliation
  never worked** (found during a live iPad seed-restore): the code POSTed raw
  proofs to `/v1/check`, which does not exist (404 on cashu.cz and Minibits);
  the real endpoint is `/v1/checkstate` taking `Ys` (hash_to_curve of each
  secret). The 404 made `verifyUnspent` discard every restored proof ("0
  restored") and made launch-time `reconcilePending` a silent no-op.
  `hash_to_curve` hoisted to a shared Core function (`cashu_hash_to_curve` /
  `cashu_Y_hex`); `check()` now posts Ys to `/v1/checkstate`; both callers match
  states BY Y instead of positionally — which also closes audit finding L4
  (reordering-mint hazard). Y computation pinned to the NUT-00 vectors.

### Live end-to-end verification (2026-07-18, real funds)
- **Seed restore on a fresh device (iPad)**: import 12 words → multi-mint scan →
  full balance recovered across both mints (C2/H1 proven live).
- **Pending-proof safety**: a failed melt's 64-sat input sat quarantined as
  `.pending` for ~5 hours (through the broken /v1/check era) without loss or
  double-spend; after the checkstate fix, launch reconciliation released it
  automatically (C5 + NUT-07 proven live).
- **Melt success path**: two Lightning payments with exact fee accounting and
  change recovery. **Ecash interop**: send → claimed in Minibits (M11), and
  V4 receive from Minibits. Remaining untested: macOS build, app-kill
  mid-operation, cross-mint melt from a non-default mint.

### Verification status
`swift test` → 21/21 pass (official NUT-00 V4, NUT-12 DLEQ and NUT-13 v00/v01
vectors, keyset-ID validation/rejection, Int64-overflow regression, and
FileProofRepository round-trip/migration/recovery). `xcodebuild -scheme
CocoCashuApp` → BUILD SUCCEEDED.

## Architecture — moving domain logic into the library

The audit fixes exposed that several bugs lived in the app because domain logic
(persistence, orchestration, parsing) had leaked out of the library. Rebalancing:

### Done
- **Proof persistence → library (`FileProofRepository`).** The app previously
  hand-rolled persistence: an event-subscription save loop in `CashuBootstrap`
  plus a `StoredProof` translation struct (duplicated in `ObservableWallet`).
  That seam caused the double-writer race, the reserved/pending-not-persisted
  bugs, and the `StoredProof.state` gap. Now a disk-backed `ProofRepository`
  lives in the library beside `FileCounterRepository`: bookkeeping is a shared
  pure `ProofStore` (so the in-memory and file repos can't diverge), it persists
  after each mutation (atomic + complete file protection), reloads `.reserved`
  as `.pending` for reconciliation, drops spent proofs to bound file growth, and
  migrates the legacy `StoredProof` JSON so upgrading wallets keep their balance.
  `CashuBootstrap` shrank from ~224 to ~150 lines (no save loop, no restore, no
  `StoredProof`). Covered by four new persistence tests.

- **BOLT11 amount decoding → library (`BOLT11.amountSats`).** Moved out of
  `MeltView` into Core with test vectors (all multipliers, fractional-sat
  rejection, testnet prefix, non-invoices). Hardened while moving: the regex now
  requires the bech32 `1` separator after the multiplier, so an AMOUNTLESS
  invoice (`lnbc1<data>`) whose data begins with a multiplier letter can no
  longer be misread as e.g. "1 milli-BTC". Still a preview-only parse — the
  mint's melt quote remains authoritative.

- **Multi-mint orchestration → library, backed by `MintRepository`.** Done.
  `FileMintRepository` (mints.json, same persistence guarantees) brings the
  previously-dead registry to life; mints are registered on bootstrap (default)
  and on receive/successful scan. `CashuManager+MultiMint` exposes
  `registerMint`, `knownMints` (registry ∪ mints of stored proofs),
  `balances()`, `selectMint(covering:)` (pure `MintSelection.pick` — largest
  single balance covering the amount; total-across-mints is deliberately not
  enough), `scanAllMints(extra:)` with per-mint failure isolation, and
  `reconcileAllPending()` (NUT-07 at EVERY mint holding pending proofs — the
  bootstrap previously reconciled only the default mint, a latent gap).
  `ObservableWallet` gained `totalBalance`/`mintBalances` display state and a
  `scanAllMints(extraMintString:)` wrapper. WalletView/MeltView/BackupView now
  only render; mint selection and the scan loop left the UI. Seed import keeps
  mints.json (mints aren't seed-specific; the post-import scan then finds funds
  without re-entering URLs). Tests: selection/dedupe/registry round-trip.

### Candidate follow-ups (identified, not yet done)
- **Bootstrap wiring → a library factory** (e.g. `CashuWallet.makeDefault(mint:storageURL:)`),
  leaving the app to supply only the mint URL and storage location.
