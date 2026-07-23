import Foundation
#if os(iOS)
import CoreNFC

/// NFC read/write of Cashu tokens via NDEF records, using `NFCTagReaderSession`.
///
/// Why the tag session (not `NFCNDEFReaderSession`): App Store validation for
/// the iOS 26 SDK rejects the legacy `NDEF` value in the
/// `com.apple.developer.nfc.readersession.formats` entitlement ("NDEF is
/// disallowed", ITMS-90778). Only `TAG` is allowed, which means detecting raw
/// tags and doing NDEF I/O through the concrete tag types — all of which
/// (MiFare/ISO7816/ISO15693/FeliCa) conform to `NFCNDEFTag`, so the NDEF
/// read/write logic is unchanged.
///
/// Platform reality (checked 2026-07): iOS does NOT allow one iPhone to present
/// itself as a tag to another iPhone outside the EEA (Host Card Emulation is
/// entitlement-gated and region-locked), so true "tap two iPhones" is not
/// available here. What IS available with the standard tag-reading capability:
///   • READ a token from a physical NFC card/sticker, or from an Android wallet
///     acting as an HCE tag;
///   • WRITE a token onto a writable NDEF card (an offline bearer "Cashu card").
/// For iPhone↔iPhone, use the QR path (TokenQRView/TokenQRDisplay) instead.
///
/// Requires the "Near Field Communication Tag Reading" capability with format
/// TAG only, and NFCReaderUsageDescription. Until the capability is present,
/// `isAvailable` is false and the calls no-op gracefully.
@MainActor
final class NFCService: NSObject {
    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    private var session: NFCTagReaderSession?
    private var onToken: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var tokenToWrite: String?

    /// Present the system NFC sheet and read a Cashu token from the first tag
    /// that carries one (in an NDEF text or URI record).
    func readToken(onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard Self.isAvailable else {
            onError("NFC is not available on this device.")
            return
        }
        self.onToken = onToken
        self.onError = onError
        self.tokenToWrite = nil
        beginSession(alertMessage: "Hold your iPhone near the Cashu card or tag.")
    }

    /// Present the system NFC sheet and write `token` onto the first writable
    /// NDEF tag tapped (creates an offline bearer "Cashu card").
    func writeToken(_ token: String, onSuccess: @escaping () -> Void, onError: @escaping (String) -> Void) {
        guard Self.isAvailable else {
            onError("NFC is not available on this device.")
            return
        }
        self.tokenToWrite = token
        self.onToken = { _ in onSuccess() }
        self.onError = onError
        beginSession(alertMessage: "Hold your iPhone near a writable NFC card to load the token.")
    }

    private func beginSession(alertMessage: String) {
        // .iso14443 covers NTAG/MiFare cards and Android HCE; .iso15693 covers
        // vicinity tags. Both families' tag objects conform to NFCNDEFTag.
        session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil)
        session?.alertMessage = alertMessage
        session?.begin()
    }

    /// The concrete tag behind an `NFCTag`, as an NDEF-capable tag.
    nonisolated private static func ndefTag(from tag: NFCTag) -> NFCNDEFTag? {
        switch tag {
        case .miFare(let t): return t
        case .iso7816(let t): return t
        case .iso15693(let t): return t
        case .feliCa(let t): return t
        @unknown default: return nil
        }
    }

    nonisolated private static func token(in message: NFCNDEFMessage) -> String? {
        for record in message.records {
            // Text record: [status byte][lang code][UTF-8 text]
            if record.typeNameFormat == .nfcWellKnown,
               let type = String(data: record.type, encoding: .utf8) {
                if type == "T" {
                    let payload = record.payload
                    guard payload.count > 1 else { continue }
                    let langLen = Int(payload[0] & 0x3F)
                    let textStart = 1 + langLen
                    if payload.count > textStart,
                       let text = String(data: payload.subdata(in: textStart..<payload.count), encoding: .utf8),
                       isCashuToken(text) {
                        return text
                    }
                } else if type == "U", let uri = record.wellKnownTypeURIPayload()?.absoluteString {
                    // URI record, possibly a cashu:<token> scheme.
                    let stripped = uri.replacingOccurrences(of: "cashu:", with: "")
                    if isCashuToken(stripped) { return stripped }
                }
            }
        }
        return nil
    }

    nonisolated private static func isCashuToken(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("cashuA") || t.hasPrefix("cashuB")
    }
}

extension NFCService: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            // User-cancel isn't a real error.
            let nfcErr = error as? NFCReaderError
            if nfcErr?.code != .readerSessionInvalidationErrorUserCanceled {
                self.onError?(error.localizedDescription)
            }
            self.session = nil
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first, let ndef = NFCService.ndefTag(from: tag) else {
            session.invalidate(errorMessage: "This tag type isn't supported.")
            return
        }
        let writeToken = Task { @MainActor in self.tokenToWrite }
        session.connect(to: tag) { error in
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            Task {
                let pending = await writeToken.value
                if let pending {
                    Self.write(pending, to: ndef, session: session) { [weak self] result in
                        Task { @MainActor in
                            switch result {
                            case .success: session.alertMessage = "Token written."; session.invalidate(); self?.onToken?("")
                            case .failure(let e): session.invalidate(errorMessage: e.localizedDescription)
                            }
                        }
                    }
                } else {
                    ndef.readNDEF { [weak self] message, _ in
                        Task { @MainActor in
                            if let message, let token = NFCService.token(in: message) {
                                session.alertMessage = "Token received."
                                session.invalidate()
                                self?.onToken?(token)
                            } else {
                                session.invalidate(errorMessage: "No Cashu token found on this tag.")
                            }
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func write(_ token: String, to tag: NFCNDEFTag, session: NFCTagReaderSession,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        let payload = NFCNDEFPayload.wellKnownTypeTextPayload(string: token, locale: Locale(identifier: "en"))
        guard let payload else {
            completion(.failure(NSError(domain: "NFC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not encode token."])))
            return
        }
        let message = NFCNDEFMessage(records: [payload])
        tag.queryNDEFStatus { status, capacity, _ in
            guard status == .readWrite else {
                completion(.failure(NSError(domain: "NFC", code: -2, userInfo: [NSLocalizedDescriptionKey: "This tag is not writable."])))
                return
            }
            guard message.length <= capacity else {
                completion(.failure(NSError(domain: "NFC", code: -3, userInfo: [NSLocalizedDescriptionKey: "Token is too large for this tag (\(message.length) > \(capacity) bytes). Use a higher-capacity NFC card."])))
                return
            }
            tag.writeNDEF(message) { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }
}
#endif
