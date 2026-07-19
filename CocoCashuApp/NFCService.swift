import Foundation
#if os(iOS)
import CoreNFC

/// NFC read/write of Cashu tokens via NDEF.
///
/// Platform reality (checked 2026-07): iOS does NOT allow one iPhone to present
/// itself as a tag to another iPhone outside the EEA (Host Card Emulation is
/// entitlement-gated and region-locked), so true "tap two iPhones" is not
/// available here. What IS available with the standard "Near Field Communication
/// Tag Reading" capability:
///   • READ a token from a physical NFC card/sticker, or from an Android wallet
///     acting as an HCE tag;
///   • WRITE a token onto a writable NDEF card (an offline bearer "Cashu card").
/// For iPhone↔iPhone, use the QR path (TokenQRView) instead.
///
/// Requires (set up once in Xcode → Signing & Capabilities):
///   • "Near Field Communication Tag Reading" capability (generates the
///     com.apple.developer.nfc.readersession.formats entitlement), and
///   • NFCReaderUsageDescription in Info.plist (set via build setting).
/// Until that capability is added, `isAvailable` is false and the calls no-op
/// gracefully — the app still builds and runs.
@MainActor
final class NFCService: NSObject {
    static var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    private var session: NFCNDEFReaderSession?
    private var onToken: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var tokenToWrite: String?

    /// Present the system NFC sheet and read a Cashu token from the first tag
    /// that carries one (in an NDEF text or URI record).
    func readToken(onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard NFCNDEFReaderSession.readingAvailable else {
            onError("NFC is not available on this device.")
            return
        }
        self.onToken = onToken
        self.onError = onError
        self.tokenToWrite = nil
        session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        session?.alertMessage = "Hold your iPhone near the Cashu card or tag."
        session?.begin()
    }

    /// Present the system NFC sheet and write `token` onto the first writable
    /// NDEF tag tapped (creates an offline bearer "Cashu card").
    func writeToken(_ token: String, onSuccess: @escaping () -> Void, onError: @escaping (String) -> Void) {
        guard NFCNDEFReaderSession.readingAvailable else {
            onError("NFC is not available on this device.")
            return
        }
        self.tokenToWrite = token
        self.onToken = { _ in onSuccess() }
        self.onError = onError
        session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        session?.alertMessage = "Hold your iPhone near a writable NFC card to load the token."
        session?.begin()
    }

    private static func token(in message: NFCNDEFMessage) -> String? {
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

    private static func isCashuToken(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("cashuA") || t.hasPrefix("cashuB")
    }
}

extension NFCService: NFCNDEFReaderSessionDelegate {
    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            // User-cancel and "first read" completion aren't real errors.
            let nfcErr = error as? NFCReaderError
            if nfcErr?.code != .readerSessionInvalidationErrorUserCanceled,
               nfcErr?.code != .readerSessionInvalidationErrorFirstNDEFTagRead {
                self.onError?(error.localizedDescription)
            }
            self.session = nil
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // Only used for the read-without-connect path; write/read use didDetect tags.
        Task { @MainActor in
            for message in messages {
                if let token = NFCService.token(in: message) {
                    session.alertMessage = "Token received."
                    session.invalidate()
                    self.onToken?(token)
                    return
                }
            }
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else { return }
        let writeToken = Task { @MainActor in self.tokenToWrite }
        session.connect(to: tag) { error in
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            Task {
                let pending = await writeToken.value
                if let pending {
                    Self.write(pending, to: tag, session: session) { [weak self] result in
                        Task { @MainActor in
                            switch result {
                            case .success: session.alertMessage = "Token written."; session.invalidate(); self?.onToken?("")
                            case .failure(let e): session.invalidate(errorMessage: e.localizedDescription)
                            }
                        }
                    }
                } else {
                    tag.readNDEF { [weak self] message, _ in
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

    private static func write(_ token: String, to tag: NFCNDEFTag, session: NFCNDEFReaderSession,
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
