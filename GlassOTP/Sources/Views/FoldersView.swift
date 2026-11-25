import GlassOTPCore
import SwiftUI

struct FoldersView: View {
    @Environment(VaultViewModel.self) private var vault
    let onSelectFolder: (UUID?) -> Void

    @State private var showingEditor = false
    @State private var editingFolder: OTPFolder?
    @State private var deletingFolder: OTPFolder?
    @State private var folderName = ""
    @State private var folderSymbol = "folder.fill"

    private let symbolOptions = [
        "folder.fill", "house.fill", "briefcase.fill", "server.rack",
        "building.columns.fill", "lock.shield.fill", "globe", "terminal.fill",
        "creditcard.fill", "gamecontroller.fill", "sparkles", "star.fill",
    ]

    var body: some View {
        ZStack {
            AmbientGlassBackground()

            ScrollView {
                VStack(spacing: 8) {
                    folderRow(
                        title: "All Accounts",
                        subtitle: "\(vault.accounts.count) total tokens",
                        symbol: "tray.full.fill",
                        tint: Color.accentColor,
                        action: { onSelectFolder(nil) }
                    )

                    if vault.folders.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "folder.badge.plus")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No Folders Yet")
                                .font(.headline)
                            Text("Create folders to group Personal, Work, or Infrastructure tokens — or import a backup from OTP Auth to bring your existing folders along.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.top, 12)
                    } else {
                        ForEach(vault.folders) { folder in
                            let count = vault.accountsCount(in: folder.id)
                            folderRow(
                                title: folder.name,
                                subtitle: "\(count) \(count == 1 ? "account" : "accounts")",
                                symbol: folder.symbolName,
                                tint: .indigo,
                                action: { onSelectFolder(folder.id) }
                            )
                            .contextMenu {
                                Button {
                                    editingFolder = folder
                                    folderName = folder.name
                                    folderSymbol = folder.symbolName
                                    showingEditor = true
                                } label: {
                                    Label("Edit Folder", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    deletingFolder = folder
                                } label: {
                                    Label("Delete Folder", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Folders")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    vault.showingAutoCategorizeSheet = true
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .disabled(vault.accounts.isEmpty)
                .accessibilityLabel("Auto-Categorize Vault")

                Button {
                    editingFolder = nil
                    folderName = ""
                    folderSymbol = "folder.fill"
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                Form {
                    Section("Folder Name") {
                        TextField("e.g. Work, Personal, Infra", text: $folderName)
                    }
                    Section("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                            ForEach(symbolOptions, id: \.self) { symbol in
                                Button {
                                    folderSymbol = symbol
                                } label: {
                                    Image(systemName: symbol)
                                        .font(.title3)
                                        .frame(width: 42, height: 42)
                                        .background(
                                            folderSymbol == symbol ? Color.accentColor.opacity(0.25) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        )
                                        .foregroundStyle(folderSymbol == symbol ? Color.accentColor : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .navigationTitle(editingFolder == nil ? "New Folder" : "Edit Folder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let saved: Bool
                            if let existing = editingFolder {
                                saved = vault.renameFolder(existing, to: folderName, symbolName: folderSymbol)
                            } else {
                                saved = vault.addFolder(name: folderName, symbolName: folderSymbol)
                            }
                            if saved {
                                showingEditor = false
                            }
                        }
                        .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            "Delete Folder \"\(deletingFolder?.name ?? "")\"?",
            isPresented: Binding(
                get: { deletingFolder != nil },
                set: { if !$0 { deletingFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folder = deletingFolder {
                    vault.deleteFolder(folder)
                    deletingFolder = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deletingFolder = nil
            }
        } message: {
            Text("Accounts inside this folder won't be deleted — they will move to Uncategorized.")
        }
    }

    private func folderRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
