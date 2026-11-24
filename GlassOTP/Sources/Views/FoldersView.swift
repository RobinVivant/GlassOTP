import GlassOTPCore
import SwiftUI

struct FoldersView: View {
    @Environment(VaultViewModel.self) private var vault
    let onSelectFolder: (UUID?) -> Void

    @State private var showingEditor = false
    @State private var editingFolder: OTPFolder?
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
                VStack(spacing: 12) {
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
                                    vault.deleteFolder(folder)
                                } label: {
                                    Label("Delete Folder", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Folders")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                            if let existing = editingFolder {
                                vault.renameFolder(existing, to: folderName, symbolName: folderSymbol)
                            } else {
                                vault.addFolder(name: folderName, symbolName: folderSymbol)
                            }
                            showingEditor = false
                        }
                        .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
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
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
