import SwiftUI
import CocoCashuCore // Ensure this is imported to access SeedManager

struct BackupView: View {
    @State private var words: [String] = []
    @State private var isRevealed = false
    @State private var copied = false
    
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
                        UIPasteboard.general.string = string
                        copied = true
                        
                        // Haptic Feedback
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        
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
        }
        .navigationTitle("Backup")
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
}