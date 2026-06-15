import SwiftUI
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
                    
                    Button {
                        let string = words.joined(separator: " ")
                        #if os(iOS)
                        UIPasteboard.general.string = string
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(string, forType: .string)
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
                Text("This scans the mint for any tokens derived from your seed that are not currently on your device.")
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
        // In a real app, you would ask for FaceID/TouchID here first!
        if let phrase = SeedManager.shared.retrieveFromKeychain() {
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
                // 1. Call the clean function on Wallet
                let count = try await wallet.scanForFunds(mint: activeMint)
                
                // 2. Handle Success
                alertMessage = "Restored \(count) tokens!"
                showAlert = true
            } catch {
                // 3. Handle Error
                alertMessage = "Error: \(error.localizedDescription)"
                showAlert = true
            }
            isScanning = false
        }
    }
}
