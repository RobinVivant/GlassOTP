import GlassOTPCore
import SwiftUI

enum AppTab: Hashable {
    case vault
    case folders
    case settings
    case search
}

struct RootTabView: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var selectedTab: AppTab = .vault
    @State private var searchQuery = ""

    var body: some View {
        @Bindable var bindableVault = vault

        TabView(selection: $selectedTab) {
            Tab("Vault", systemImage: "lock.shield.fill", value: AppTab.vault) {
                NavigationStack {
                    VaultHomeView()
                }
            }

            Tab("Folders", systemImage: "folder.fill", value: AppTab.folders) {
                NavigationStack {
                    FoldersView(onSelectFolder: { folderID in
                        vault.selectedFolderID = folderID
                        selectedTab = .vault
                    })
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }

            Tab(value: AppTab.search, role: .search) {
                NavigationStack {
                    SearchVaultView(query: $searchQuery)
                }
                .searchable(text: $searchQuery, prompt: "Search issuer or account")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .bottom) {
            if let toast = vault.copiedToast {
                FloatingCopyToast(toast: toast)
                    .padding(.bottom, 74)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $bindableVault.showingImportSheet) {
            OTPAuthImportSheet(initialFile: vault.pendingImportFile) {
                vault.pendingImportFile = nil
            }
        }
        .sheet(isPresented: $bindableVault.showingScannerSheet) {
            QRScannerSheet { parsedAccounts in
                if parsedAccounts.count == 1, let single = parsedAccounts.first {
                    vault.editingAccount = single
                } else if !parsedAccounts.isEmpty {
                    let count = vault.importAccounts(parsedAccounts, folders: [], skipDuplicates: true)
                    if count == 0 {
                        vault.alertMessage = "All scanned accounts are already in your vault."
                    }
                }
            }
        }
        .sheet(isPresented: $bindableVault.showingNewAccountSheet) {
            AccountEditorSheet(account: nil, defaultFolderID: vault.selectedFolderID)
        }
        .sheet(isPresented: $bindableVault.showingAutoCategorizeSheet) {
            AutoCategorizeSheet()
        }
        .sheet(item: $bindableVault.editingAccount) { account in
            AccountEditorSheet(account: account, defaultFolderID: account.folderID)
        }
        .sheet(item: $bindableVault.brandPickerAccount) { account in
            BrandPickerSheet(account: account)
        }
        .sheet(item: $bindableVault.qrDetailAccount) { account in
            AccountQRDetailSheet(account: account)
        }
        .alert("Notice", isPresented: Binding(
            get: { vault.alertMessage != nil },
            set: { if !$0 { vault.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vault.alertMessage ?? "")
        }
        .alert(
            "Import \(vault.pendingURIAccounts?.count ?? 0) Accounts?",
            isPresented: Binding(
                get: { vault.pendingURIAccounts != nil },
                set: { if !$0 { vault.pendingURIAccounts = nil } }
            )
        ) {
            Button("Import All") {
                if let incoming = vault.pendingURIAccounts {
                    vault.importAccounts(incoming, folders: [], skipDuplicates: true)
                    vault.pendingURIAccounts = nil
                }
            }
            Button("Cancel", role: .cancel) {
                vault.pendingURIAccounts = nil
            }
        } message: {
            Text("Add the scanned migration accounts to your vault?")
        }
    }
}

private struct SearchVaultView: View {
    @Environment(VaultViewModel.self) private var vault
    @Binding var query: String

    var body: some View {
        ZStack {
            AmbientGlassBackground()

            let results = vault.searchResults(for: query)
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(results) { account in
                            OTPCardView(
                                account: account,
                                folderName: vault.folderName(for: account.folderID)
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
    }
}
