import SwiftUI
import UniformTypeIdentifiers

/// Destination picker plus vault configuration. Shown inside SettingsView.
struct VaultSettingsSection: View {

    @State private var destination = AppSettings.destinationKind
    @State private var notesFolder = AppSettings.vaultNotesFolder
    @State private var attachmentsFolder = AppSettings.vaultAttachmentsFolder
    @State private var isPickingFolder = false
    @State private var vaultPath: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            Section("Destination") {
                Picker("Send notes to", selection: $destination) {
                    ForEach(DestinationKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .onChange(of: destination) { _, newValue in
                    AppSettings.destinationKind = newValue
                }
            }

            if destination == .vault {
                Section("Obsidian Vault") {
                    Button {
                        isPickingFolder = true
                    } label: {
                        HStack {
                            Text(vaultPath == nil ? "Choose Vault Folder…" : "Change Vault Folder…")
                            Spacer()
                            if let vaultPath {
                                Text(vaultPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }

                    TextField("Notes subfolder (blank = vault root)", text: $notesFolder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { AppSettings.vaultNotesFolder = notesFolder }
                        .onChange(of: notesFolder) { _, newValue in
                            AppSettings.vaultNotesFolder = newValue
                        }

                    TextField("Attachments subfolder", text: $attachmentsFolder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { AppSettings.vaultAttachmentsFolder = attachmentsFolder }
                        .onChange(of: attachmentsFolder) { _, newValue in
                            AppSettings.vaultAttachmentsFolder = newValue
                        }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try VaultBookmarkStore.save(url: url)
                    vaultPath = url.lastPathComponent
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            notesFolder = AppSettings.vaultNotesFolder
            attachmentsFolder = AppSettings.vaultAttachmentsFolder
            refreshVaultPath()
        }
    }

    private func refreshVaultPath() {
        do {
            vaultPath = try VaultBookmarkStore.resolve().lastPathComponent
            errorMessage = nil
        } catch VaultAccessError.notConfigured {
            vaultPath = nil
            errorMessage = nil
        } catch {
            vaultPath = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
