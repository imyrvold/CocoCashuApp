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
        }
    }
}
