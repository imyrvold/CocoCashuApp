import SwiftUI
import CocoCashuCore

struct RestoreView: View {
    @State private var wordsInput: String = ""
    @State private var status: String = ""
    @State private var isRestoring = false
    @Environment(\.dismiss) var dismiss
    
    // We need a way to trigger the "restart" or reload logic
    var onRestoreSuccess: () -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Recovery Phrase") {
                    TextField("army van defense...", text: $wordsInput, axis: .vertical)
                        .lineLimit(3...4)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    
                    Text("Enter your 12-word seed phrase separated by spaces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section {
                    Button {
                        restoreWallet()
                    } label: {
                        if isRestoring {
                            ProgressView()
                        } else {
                            Text("Restore Wallet")
                        }
                    }
                    .disabled(wordsInput.split(separator: " ").count != 12 || isRestoring)
                }
                
                if !status.isEmpty {
                    Section {
                        Text(status)
                    }
                }
            }
            .navigationTitle("Import Wallet")
        }
    }
    
    private func restoreWallet() {
        let words = wordsInput.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            
        guard words.count == 12 else {
            status = "Please enter exactly 12 words."
            return
        }
        
        guard SeedManager.shared.isValid(words) else {
            status = "Invalid seed phrase (checksum failed)."
            return
        }
        
        isRestoring = true
        status = "Saving seed..."
        
        // 1. Overwrite Keychain
        try? SeedManager.shared.saveToKeychain(phrase: words)
        
        // 2. Trigger App Reload
        // In a real app, you might swap the Root View. 
        // Here we call the closure to let the parent handle it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            onRestoreSuccess()
        }
    }
}
