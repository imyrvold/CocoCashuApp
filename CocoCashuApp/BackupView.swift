import SwiftUI
import LocalAuthentication
import CocoCashuUI
import CocoCashuCore

struct BackupView: View {
    @State private var words: [String] = []
    @State private var isRevealed = false
    @State private var copied = false
    @State private var isScanning = false
    @State private var isRestoring = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showImportSheet = false
    @State private var showResetConfirm = false
    @State private var showClearConfirm = false
    @State private var customMintURL = ""
    @Environment(\.scenePhase) private var scenePhase
    let wallet: ObservableWallet
    let activeMint: URL

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Secret Recovery Phrase")
                        .font(.headline)
                    Text("Write down these 12 words on paper and store them safely. If you lose your phone, this is the ONLY way to recover your funds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
            
            Section {
                if isRevealed {
                    // Grid Layout for Words
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                        ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                            HStack {
                                Text("\(index + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                Text(word)
                                    .font(.system(.body, design: .monospaced))
                                    .bold()
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.vertical)
                    .privacySensitive()

                    Button {
                        let string = words.joined(separator: " ")
                        #if os(iOS)
                        // The seed is total wallet control. Keep it off Universal
                        // Clipboard (.localOnly) and auto-purge it (.expirationDate)
                        // so it can't linger for other apps or sync to nearby devices.
                        UIPasteboard.general.setItems(
                            [["public.utf8-plain-text": string]],
                            options: [
                                .localOnly: true,
                                .expirationDate: Date().addingTimeInterval(60)
                            ]
                        )
                        #elseif os(macOS)
                        // macOS has no per-item expiry, but mark the item "concealed"
                        // so clipboard-history managers skip persisting the seed.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(string, forType: .string)
                        NSPasteboard.general.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
                        #endif
                        copied = true
                        
                        // Haptic Feedback
                        #if os(iOS)
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        #endif
                        
                        // Reset "Copied" text after 2s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied!" : "Copy to Clipboard")
                        }
                    }
                } else {
                    Button {
                        revealSeed()
                    } label: {
                        HStack {
                            Image(systemName: "eye")
                            Text("Tap to Reveal Seed")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                }
            } footer: {
                if isRevealed {
                    Text("Never share these words with anyone.")
                        .foregroundStyle(.red)
                }
            }
            
            Section {
                Text("Scan for Lost Funds")
                    .font(.headline)
                    .padding(.vertical, 5)
            }
            
            Section {
                TextField("Extra mint URL to scan (optional)", text: $customMintURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif

                Button {
                    startScan() // Call helper function
                } label: {
                    HStack {
                        if isScanning {
                            ProgressView()
                                .padding(.trailing, 5)
                        } else {
                            Image(systemName: "square.and.arrow.down.fill")
                        }
                        Text(isScanning ? "Scanning..." : "Scan for Lost Funds")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .disabled(isScanning)
            } header: {
                Text("Recovery")
            } footer: {
                Text("Scans every mint this wallet knows (the default mint and any mint you hold funds at) for tokens derived from your seed that are not on this device. If you held funds at another mint before restoring, enter its URL above so it gets scanned too.")
            }
            
            Section {
                Button {
                    showImportSheet = true
                } label: {
                    Label("Import / Recover Wallet", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.red)
                }

                Button {
                    showClearConfirm = true
                } label: {
                    Label("Clear Balance (Keep Wallet)", systemImage: "trash")
                        .foregroundStyle(.red)
                }

                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset Wallet (New Seed)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Clear Balance removes local proofs but keeps your seed and derivation counter (safe). Reset Wallet generates a brand-new seed — only its recovery phrase can restore any future funds.")
            }
        }
        .navigationTitle("Backup")
        // Don't leave the 12 words sitting in view/state once the user navigates
        // away or the app backgrounds — the reveal is a deliberate, momentary act.
        .onDisappear { hideSeed() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hideSeed() }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportWalletView()
        }
        .alert("Scan Complete", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Clear Balance?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear & Quit", role: .destructive) {
                CashuBootstrap.clearBalance()
                exit(0)
            }
        } message: {
            Text("This deletes the proofs stored on this device. Your seed and counter are kept. The app will close — reopen it to continue.")
        }
        .alert("Reset Wallet?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset & Quit", role: .destructive) {
                CashuBootstrap.resetWalletNewSeed()
                exit(0)
            }
        } message: {
            Text("This permanently deletes the current seed and all local funds, then generates a NEW wallet on next launch. Back up your recovery phrase first if you need it. The app will close — reopen it to start fresh.")
        }
    }
    
    private func revealSeed() {
        // The seed is total wallet control: require the device owner
        // (FaceID/TouchID with passcode fallback) before showing it. Without this,
        // anyone holding the unlocked phone reads the 12 words in two taps.
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // No passcode set on the device — nothing to authenticate against.
            // Reveal (the device itself is unprotected; that is the user's choice).
            loadAndShowSeed()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Authenticate to reveal your recovery phrase") { success, _ in
            guard success else { return }
            Task { @MainActor in
                loadAndShowSeed()
            }
        }
    }

    private func hideSeed() {
        isRevealed = false
        words = []
    }

    private func loadAndShowSeed() {
        // (try? is safe here: a keychain error just means nothing is revealed.)
        if let phrase = (try? SeedManager.shared.retrieveFromKeychain()) ?? nil {
            self.words = phrase
            withAnimation {
                isRevealed = true
            }
        }
    }
    
    private func startScan() {
        isScanning = true
        Task {
            do {
                // The library scans every known mint (registry + mints holding
                // proofs) plus the optional user-entered URL, with per-mint
                // failure isolation. This view only renders the outcomes.
                let outcomes = try await wallet.scanAllMints(extraMintString: customMintURL)
                let total = outcomes.compactMap(\.restored).reduce(0, +)
                let lines = outcomes.map { o in
                    let label = o.mint.host ?? o.mint.absoluteString
                    if let count = o.restored {
                        return "\(label): \(count) restored"
                    }
                    return "\(label): scan failed (\(o.errorDescription ?? "unknown error"))"
                }
                alertMessage = "Restored \(total) token(s) across \(outcomes.count) mint(s).\n\n" + lines.joined(separator: "\n")
            } catch {
                alertMessage = "Error: \(error.localizedDescription)"
            }
            showAlert = true
            isScanning = false
        }
    }
}
