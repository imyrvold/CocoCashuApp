# CocoCashu 🥥

A native, cross-platform Cashu wallet for iOS and macOS, built specifically for the Swift ecosystem. CocoCashu demonstrates how to build a self-custodial ecash wallet using the [CocoCashuSwift](https://github.com/imyrvold/CocoCashuSwift) library.

<p align="center">
  <img src="https://via.placeholder.com/150" alt="CocoCashu Icon" width="120" height="120">
</p>

## ## Features

- ****Multi-Mint Support:**** Manage balances across multiple mints (e.g., Minibits, Cashu.cz).
- ****Cross-Platform:**** Runs natively on iOS and macOS with a shared codebase.
- ****Lightning Integration:**** Mint tokens via Lightning invoices and melt tokens back to Lightning.
- ****Ecash Transfers:**** Send and receive ecash tokens instantly.
- ****Privacy Focused:**** Self-custodial; all secrets and proofs are stored locally on your device.
- ****Robust Recovery:**** Built-in history tracking and proof management.

## Requirements

- ****iOS:**** 17.0+
- ****macOS:**** 14.0+
- ****Xcode:**** 15.0+
- ****Swift:**** 5.9+

## Installation

1. Clone the repository:
   ```bash
   git clone [https://github.com/imyrvold/CocoCashuApp.git](https://github.com/imyrvold/CocoCashuApp.git)
   ```
2. Open `CocoCashuApp.xcodeproj` in Xcode.
3. Ensure the `CocoCashuSwift` package dependencies are resolved (File > Packages > Resolve Package Versions).
4. Select your target (My Mac or iPhone Simulator) and hit Run (Cmd+R).

## Architecture
The app is built using the **MVVM** pattern and relies heavily on the modular CocoCashuSwift library:
* **CocoCashuApp:** The pure SwiftUI layer. Contains Views (WalletView, MintManagementView) and binds to the ViewModels.
* **CocoCashuUI (Library):** Contains the "View Models" like ObservableWallet and MintCoordinator.
* **CocoCashuCore (Library):** Handles the heavy lifting—Cryptography, Networking (RealMintAPI), and Database (ProofRegistry).

## Contributing
Pull requests are welcome! Please ensure you test changes on both macOS and iOS targets.
## License
This project is licensed under the MIT License.

