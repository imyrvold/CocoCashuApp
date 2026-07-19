// WalletView.swift
import SwiftUI
import Observation
import CocoCashuUI
import CocoCashuCore

struct WalletView: View {
    @Bindable var wallet: ObservableWallet
    
    // UI State
    @State private var invoiceItem: InvoiceItem? = nil

    // Minting State
    @State private var showMintSheet = false
    @State private var mintAmountString = "100"
    @State private var isRequestingQuote = false
    @State private var mintError: String? = nil

    // Payment tracking state
    @State private var isPolling = false
    @State private var paymentStatus: String? = nil

    private let activeMint = CashuBootstrap.defaultMint

    // Ecash State
    @State private var showSendSheet = false
    @State private var showReceiveSheet = false
    @State private var tokenToShare: String? = nil
    @State private var tokenInput = ""
    @State private var ecashError: String? = nil
    @State private var isProcessingEcash = false
    // Send gets its OWN amount state — reusing mintAmountString pre-filled the
    // send sheet with the last Mint amount, one tap away from an irreversible
    // over-sized bearer token.
    @State private var sendAmountString = ""
    @State private var showDiscardTokenConfirm = false
#if os(iOS)
    @State private var nfc = NFCService()
#endif
    
    @State private var showingMelt = false
    @State private var showBackup = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                
                // MARK: - Balance Card
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)
                    
                    VStack(spacing: 8) {
                        Text("Total Balance")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .textCase(.uppercase)

                        // Sum across ALL mints — receiving a token from another
                        // mint (e.g. Minibits) stores its proofs under that mint,
                        // and showing only the default mint made those funds
                        // invisible even though they were safely received.
                        (Text("\(wallet.totalBalance)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        + Text(" sats")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.9)))
                        .privacySensitive()

                        // Per-mint breakdown when funds live at more than one mint,
                        // so it's clear where the money actually is.
                        let breakdown = wallet.mintBalances
                        if breakdown.count > 1 {
                            VStack(spacing: 2) {
                                ForEach(breakdown) { entry in
                                    Text("\(entry.host): \(entry.balance) sats")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .privacySensitive()
                        }
                    }
                    .padding(.vertical, 30)
                }
                .frame(height: 160)
                .padding(.horizontal)
                
                // MARK: - Action Buttons
                HStack(spacing: 20) {
                    ActionButton(icon: "plus", label: "Mint", color: .blue) {
                        showMintSheet = true
                    }
                    .sheet(isPresented: $showMintSheet) { mintInputSheet }
                    
                    ActionButton(icon: "paperplane", label: "Send", color: .orange) {
                        showSendSheet = true // Re-use or make new sheet
                    }
                    .sheet(isPresented: $showSendSheet) { sendEcashSheet }
                    
                    ActionButton(icon: "arrow.down.doc", label: "Receive", color: .green) {
                        showReceiveSheet = true
                    }
                    .sheet(isPresented: $showReceiveSheet) { receiveEcashSheet }
                    
                    ActionButton(icon: "bolt.fill", label: "Pay", color: .purple) {
                        showingMelt = true
                    }
                    .sheet(isPresented: $showingMelt) {
                        MeltView(wallet: wallet)
                    }
                }
                .padding(.horizontal)
                
                // MARK: - Transaction History
                VStack(alignment: .leading) {
                    Text("History")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    if wallet.transactions.isEmpty {
                        ContentUnavailableView("No Transactions", systemImage: "clock", description: Text("Your recent activity will appear here."))
                    } else {
                        List {
                            ForEach(wallet.transactions) { tx in
                                TransactionRow(tx: tx)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showBackup = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .navigationDestination(isPresented: $showBackup) {
                BackupView(wallet: wallet, activeMint: activeMint)
            }
        }
        // QR Sheet logic
        .sheet(item: $invoiceItem) { item in
            paymentSheet(for: item)
        }
    }
    
    // MARK: - Helper Views
    
    private var mintInputSheet: some View {
        VStack(spacing: 20) {
            Text("Mint Tokens").font(.headline)
            Text("Enter the amount you want to receive.")
                .foregroundStyle(.secondary)
            
            TextField("Amount", text: $mintAmountString)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 150)
            
            if let err = mintError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            
            if isRequestingQuote {
                ProgressView("Requesting Invoice…")
            } else {
                HStack {
                    Button("Cancel") { showMintSheet = false }
                        .buttonStyle(.bordered)
                    Button("Get Invoice") {
                        startMintingProcess()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(Int64(mintAmountString) == nil)
                }
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 200)
#if os(iOS)
        .presentationDetents([.height(250)])
#endif
    }
    
    private func paymentSheet(for item: InvoiceItem) -> some View {
        VStack(spacing: 16) {
            InvoiceSheet(invoice: item.invoice)
            
            if let status = paymentStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(status.hasPrefix("Error") ? .red : .secondary)
            }
            
            HStack {
                if isPolling { ProgressView().controlSize(.small) }
                Spacer()
                Button("I’ve paid – Refresh") {
                    pollForPayment(item: item)
                }
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 360)
    }
    
    // MARK: - Logic
    
    private func startMintingProcess() {
        guard let amount = Int64(mintAmountString), amount > 0 else { return }
        isRequestingQuote = true
        mintError = nil
        
        Task {
            let mint = activeMint
            let manager = wallet.manager
            
            // Ensure RealMintAPI is created here (it uses the safe URLSession by default now)
            let api = RealMintAPI(baseURL: mint)
            let flow = MintCoordinator(manager: manager, api: api, blinding: manager.blinding)
            
            do {
                // 1. Get Quote
                let (invoice, qid) = try await flow.topUp(mint: mint, amount: amount)
                
                await MainActor.run {
                    self.isRequestingQuote = false
                    self.showMintSheet = false
                    self.invoiceItem = InvoiceItem(
                        invoice: invoice.trimmingCharacters(in: .whitespacesAndNewlines),
                        quoteId: qid
                    )
                    self.paymentStatus = "Waiting for payment…"
                }
                
                // 2. Start Polling (Pass the Coordinator to keep context)
                pollForPayment(item: InvoiceItem(invoice: invoice, quoteId: qid), flow: flow, amount: amount)
                
            } catch {
                await MainActor.run {
                    self.isRequestingQuote = false
                    self.mintError = error.localizedDescription
                }
            }
        }
    }
    
    private func pollForPayment(item: InvoiceItem, flow: MintCoordinator? = nil, amount: Int64 = 0) {
        self.isPolling = true
        let mint = activeMint
        
        // Reuse existing flow or create new one
        let activeFlow: MintCoordinator
        if let existing = flow {
            activeFlow = existing
        } else {
            let manager = wallet.manager
            let api = RealMintAPI(baseURL: mint)
            activeFlow = MintCoordinator(manager: manager, api: api, blinding: manager.blinding)
        }
        
        let amountToMint = (amount > 0) ? amount : (Int64(mintAmountString) ?? 0)
        
        Task {
            do {
                // 1. Wait for Payment
                try await activeFlow.pollUntilPaid(mint: mint, invoice: item.invoice, quoteId: item.quoteId)
                
                await MainActor.run { paymentStatus = "Paid. Minting tokens…" }
                
                // 2. Execute Mint (Handles 10002 Errors/Restores automatically)
                try await activeFlow.receiveTokens(mint: mint, invoice: item.invoice, quoteId: item.quoteId, amount: amountToMint)
                
                await MainActor.run {
                    paymentStatus = "Tokens received!"
                    isPolling = false
                    invoiceItem = nil
                    // Trigger UI refresh
                    // wallet.refresh() // if needed
                }
            } catch {
                await MainActor.run {
                    paymentStatus = "Error: \(error.localizedDescription)"
                    isPolling = false
                }
            }
        }
    }
    
    // Balance math and per-mint breakdown live in ObservableWallet
    // (wallet.totalBalance / wallet.mintBalances); this view only renders them.
    
    private var sendEcashSheet: some View {
        VStack(spacing: 20) {
            Text("Send Ecash").font(.headline)
            
            if let token = tokenToShare {
                // Result State
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Token Created!").font(.headline)

                // QR is the iPhone-to-iPhone hand-off: the recipient scans it
                // with their wallet camera. (V4/cashuB keeps it compact.)
                TokenQRView(content: token, size: 200)
                    .privacySensitive()

                Text(token)
                    .font(.caption2)
                    .monospaced()
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .privacySensitive()

#if os(iOS)
                if NFCService.isAvailable {
                    Button {
                        writeTokenToCard(token)
                    } label: {
                        Label("Write to NFC card", systemImage: "wave.3.right")
                    }
                }
#endif

                Button("Copy to Clipboard") {
#if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
#else
                    // The token is live money until the recipient claims it. Expire
                    // it from the pasteboard after 5 minutes so it can't be scooped
                    // up later by another app. (Not .localOnly — pasting on another
                    // of the user's own devices via Universal Clipboard is a
                    // legitimate way to share a token.)
                    UIPasteboard.general.setItems(
                        [["public.utf8-plain-text": token]],
                        options: [.expirationDate: Date().addingTimeInterval(300)]
                    )
#endif
                }
                .buttonStyle(.borderedProminent)
                
                Button("Done") {
                    // The token string is the ONLY handle on money already swapped
                    // away at the mint — never discard it silently.
                    showDiscardTokenConfirm = true
                }
                .confirmationDialog(
                    "Discard this token?",
                    isPresented: $showDiscardTokenConfirm,
                    titleVisibility: .visible
                ) {
                    Button("I've shared it — Done", role: .destructive) {
                        tokenToShare = nil
                        showSendSheet = false
                    }
                    Button("Keep Showing", role: .cancel) { }
                } message: {
                    Text("Make sure you have copied or shared the token. Once dismissed, recovering unclaimed funds requires a full seed scan.")
                }
            } else {
                // Input State
                Text("Enter amount to convert to token.")
                    .foregroundStyle(.secondary)

                TextField("Amount", text: $sendAmountString)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)

                if isProcessingEcash { ProgressView() }
                if let err = ecashError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }

                Button("Create Token") {
                    createToken()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessingEcash || Int64(sendAmountString) == nil)
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 300)
#if os(iOS)
        .presentationDetents(tokenToShare == nil ? [.height(250)] : [.large])
#endif
    }

    private var receiveEcashSheet: some View {
        VStack(spacing: 20) {
            Text("Receive Ecash").font(.headline)
            Text("Paste a Cashu token, or tap an NFC card.")
                .foregroundStyle(.secondary)

            TextEditor(text: $tokenInput)
                .frame(height: 100)
                .border(Color.gray.opacity(0.2))
                .padding(.horizontal)

            if isProcessingEcash { ProgressView() }
            if let err = ecashError {
                Text(err).foregroundStyle(.red).font(.caption)
            }

#if os(iOS)
            if NFCService.isAvailable {
                Button {
                    receiveViaNFC()
                } label: {
                    Label("Receive via NFC", systemImage: "wave.3.right")
                }
                .disabled(isProcessingEcash)
            }
#endif

            Button("Claim Token") {
                claimToken()
            }
            .buttonStyle(.borderedProminent)
            .disabled(tokenInput.isEmpty || isProcessingEcash)
        }
        .padding()
        .frame(minWidth: 300, minHeight: 300)
#if os(iOS)
        .presentationDetents([.height(320)])
#endif
    }
    
    private func createToken() {
        guard let amt = Int64(sendAmountString), amt > 0 else { return }
        
        isProcessingEcash = true
        ecashError = nil
        
        Task {
            do {
                // 1. Pick a mint that can cover the amount (library logic — a
                // Cashu token spends proofs from ONE mint, so a sufficient total
                // across mints is not enough).
                let mint: URL
                do {
                    mint = try await wallet.manager.selectMint(covering: amt)
                } catch {
                    throw NSError(domain: "Wallet", code: -1, userInfo: [NSLocalizedDescriptionKey: "No single mint holds enough balance for \(amt) sats. Tokens can only be created from one mint at a time."])
                }

                // 2. Select Proofs to Spend from that mint
                let unspent = wallet.proofsByMint[mint.absoluteString]?.filter { $0.state == .unspent } ?? []
                
                // 2. Perform Swap via MintService. Emit V4 (cashuB) — compact for
                // QR codes and NFC cards; modern wallets read it.
                let result = try await wallet.manager.mintService.swap(proofs: unspent, amount: amt, mint: mint, tokenVersion: .v4)
                
                await MainActor.run {
                    self.tokenToShare = result.token // The serialized token string
                    self.isProcessingEcash = false
                }
            } catch {
                await MainActor.run {
                    self.ecashError = error.localizedDescription
                    self.isProcessingEcash = false
                }
            }
        }
    }
    
    private func claimToken() {
        let cleanToken = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { return }
        
        isProcessingEcash = true
        ecashError = nil
        
        Task {
            do {
                // 1. Init Coordinator
                // Note: We initialize with activeMint, but the receive(token:) method
                // extracts the *actual* Mint URL from the token string itself.
                let manager = wallet.manager
                let api = RealMintAPI(baseURL: activeMint)
                let flow = MintCoordinator(manager: manager, api: api, blinding: manager.blinding)
                
                // 2. Call the new Receive Logic
                try await flow.receive(token: cleanToken)
                
                // 3. Success UI Update
                await MainActor.run {
                    self.isProcessingEcash = false
                    self.showReceiveSheet = false
                    self.tokenInput = ""
                    // Optional: Trigger a haptic feedback
#if os(iOS)
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
#endif
                }
            } catch {
                await MainActor.run {
                    self.ecashError = error.localizedDescription
                    self.isProcessingEcash = false
                }
            }
        }
    }

#if os(iOS)
    /// Read a token from an NFC card (or an Android wallet acting as a tag) into
    /// the input field, then run the normal claim path.
    private func receiveViaNFC() {
        ecashError = nil
        nfc.readToken(
            onToken: { token in
                tokenInput = token
                claimToken()
            },
            onError: { message in
                ecashError = message
            }
        )
    }

    /// Write the created token onto a writable NFC card (an offline bearer card).
    private func writeTokenToCard(_ token: String) {
        ecashError = nil
        nfc.writeToken(
            token,
            onSuccess: {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            },
            onError: { message in
                ecashError = message
            }
        )
    }
#endif
}

// MARK: - Subviews & Structs

struct ActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 50, height: 50)
                    .background(color.opacity(0.15))
                    .foregroundStyle(color)
                    .clipShape(Circle())
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct TransactionRow: View {
    let tx: CashuTransaction
    
    private var isIncoming: Bool {
        tx.type == .mint || tx.type == .receiveEcash
    }
    
    private var iconName: String {
        switch tx.type {
        case .mint:         return "arrow.down.left"
        case .melt:         return "arrow.up.right"
        case .sendEcash:    return "paperplane"
        case .receiveEcash: return "arrow.down.doc"
        }
    }
    
    private var iconColor: Color {
        switch tx.type {
        case .mint:         return .green
        case .melt:         return .purple
        case .sendEcash:    return .orange
        case .receiveEcash: return .green
        }
    }
    
    private var label: String {
        switch tx.type {
        case .mint:         return "Minted"
        case .melt:         return "Sent Lightning"
        case .sendEcash:    return "Sent Ecash"
        case .receiveEcash: return "Received Ecash"
        }
    }
    
    var body: some View {
        HStack {
            ZStack {
                Circle().fill(iconColor.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
            
            VStack(alignment: .leading) {
                Text(label)
                    .font(.body.weight(.medium))
                Text(tx.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text((isIncoming ? "+" : "-") + "\(tx.amount)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isIncoming ? .green : .primary)
                
                if tx.status == .failed {
                    Text("Failed").font(.caption).foregroundStyle(.red)
                } else if tx.fee > 0 {
                    Text("fee: \(tx.fee)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct InvoiceItem: Identifiable {
    let id = UUID()
    let invoice: String
    let quoteId: String?
}
