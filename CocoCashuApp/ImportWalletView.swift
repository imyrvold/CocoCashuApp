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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(
                            Text("Enter your 12 words separated by spaces...")
                                .foregroundStyle(.gray.opacity(wordsInput.isEmpty ? 0.5 : 0))
                                .padding(.top, 8)
                                .padding(.leading, 5),
                            alignment: .topLeading
                        )
                    
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
                Text("This will delete the current wallet from this device and replace it with the imported seed. This action cannot be undone.")
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
            
            // 2. CRITICAL: Force the user to restart the app.
            // Why? The 'CocoBlindingEngine' is loaded once at startup. 
            // It needs to be re-initialized with the NEW seed.
            errorMessage = "Success! Please fully close (kill) and restart the app to load your restored wallet."
            
        } catch {
            errorMessage = "Failed to save to Keychain: \(error.localizedDescription)"
        }
    }
}