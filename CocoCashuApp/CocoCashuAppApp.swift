//
//  CocoCashuAppApp.swift
//  CocoCashuApp
//
//  Created by Ivan C Myrvold on 18/10/2025.
//

import SwiftUI
import CocoCashuUI

@main
struct CocoCashuAppApp: App {
    @State private var wallet: ObservableWallet?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let wallet {
                    WalletView(wallet: wallet)
                } else {
                    ProgressView("Loading wallet…")
                }
            }
            .task {
                // build wallet once when app starts
                wallet = await CashuBootstrap.makeWallet()
            }
            // Privacy screen: when the app resigns active, iOS snapshots the UI
            // for the app switcher (and writes it to disk). Cover the content so
            // balances, tokens, and a possibly-revealed seed never land in that
            // snapshot or on a mirrored/recorded screen while switching apps.
            .overlay {
                if scenePhase != .active {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Image(systemName: "bitcoinsign.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                    }
                    .ignoresSafeArea()
                }
            }
            .animation(.easeOut(duration: 0.15), value: scenePhase)
        }
    }
}
