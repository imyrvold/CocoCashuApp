import SwiftUI
import CocoCashuCore

struct ImportWalletView: View {
    @Environment(\.dismiss) var dismiss
    @State private var wordsInput: String = ""
    @State private var errorMessage: String = ""
    @State private var showingConfirmation = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Recovery Phrase") {
                    // Text Editor for pasting words easily
                    TextEditor(text: $wordsInput)
                        .frame(height: 100)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            Text("Enter your 12 words separated by spaces...")
                                .foregroundStyle(.gray.opacity(wordsInput.isEmpty ? 0.5 : 0))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                    
                    Text("This will replace your current wallet. Make sure you have backed up any funds currently on this device!")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Section {
                    Button("Restore Wallet") {
                        validateAndConfirm()
                    }
                    .disabled(wordsInput.count < 10)
                }
                
                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Wallet")
            .alert("Replace Wallet?", isPresented: $showingConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Replace", role: .destructive) {
                    performImport()
                }
            } message: {
                Text("This will delete the current wallet from this device and replace it with the imported seed. This action cannot be undone. The app will close — reopen it to load the imported wallet.")
            }
        }
    }
    
    private func validateAndConfirm() {
        // clean input
        let words = wordsInput.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        guard words.count == 12 else {
            errorMessage = "Please enter exactly 12 words."
            return
        }
        
        if SeedManager.shared.isValid(words) {
            errorMessage = ""
            showingConfirmation = true
        } else {
            errorMessage = "Invalid seed phrase. Checksum failed."
        }
    }
    
    private func performImport() {
        let words = wordsInput.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            
        do {
            // 1. Overwrite Keychain
            try SeedManager.shared.saveToKeychain(phrase: words)

            // 2. Wipe all state belonging to the OLD seed (proofs, counters,
            // history). Keeping it would show the old balance against the new
            // seed and keep the old derivation counters.
            CashuBootstrap.resetStateForImportedSeed()

            // 3. Terminate so next launch rebuilds the engine from the NEW seed.
            // The running CocoBlindingEngine was initialized with the old seed and
            // must not keep minting on it while BackupView shows the new phrase.
            // (Same close-and-relaunch pattern as the reset buttons in BackupView.)
            exit(0)

        } catch {
            errorMessage = "Failed to save to Keychain: \(error.localizedDescription)"
        }
    }
}
