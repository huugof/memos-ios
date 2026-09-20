import SwiftUI
import UniformTypeIdentifiers

/// Destination picker plus vault configuration. Shown inside SettingsView.
struct VaultSettingsSection: View {

    @State private var destination = AppSettings.destinationKind
    @State private var notesFolder = AppSettings.vaultNotesFolder
    @State private var attachmentsFolder = AppSettings.vaultAttachmentsFolder
    @State private var templatePath = AppSettings.vaultTemplatePath
    @State private var isPickingFolder = false
    @State private var isPickingTemplate = false
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

                    Button {
                        isPickingTemplate = true
                    } label: {
                        HStack {
                            Text("Frontmatter template")
                            Spacer()
                            Text(templatePath.isEmpty ? "None" : templatePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
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
        .sheet(isPresented: $isPickingTemplate) {
            VaultTemplatePicker(selection: $templatePath)
        }
        .onChange(of: templatePath) { _, newValue in
            AppSettings.vaultTemplatePath = newValue
        }
        .onAppear {
            notesFolder = AppSettings.vaultNotesFolder
            attachmentsFolder = AppSettings.vaultAttachmentsFolder
            templatePath = AppSettings.vaultTemplatePath
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

/// Picks the Markdown file whose frontmatter seeds new notes.
///
/// The list comes from the persisted vault index rather than a file picker:
/// the index already holds every `.md` path in the vault, so this needs no
/// second bookmark and no security scope, and a path can't be mistyped.
private struct VaultTemplatePicker: View {
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss

    @State private var paths: [String] = []
    @State private var isLoaded = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                row(path: "", label: "None")
                ForEach(filtered, id: \.self) { path in
                    row(path: path, label: path)
                }
            }
            .searchable(text: $query, prompt: "Filter by path")
            .navigationTitle("Frontmatter Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if isLoaded && paths.isEmpty {
                    ContentUnavailableView(
                        "No Notes Indexed",
                        systemImage: "folder",
                        description: Text("Choose a vault and let it refresh, then pick a template.")
                    )
                }
            }
        }
        .task {
            paths = await Task.detached {
                VaultIndex.load().map(\.relativePath).sorted(by: Self.templatesFirst)
            }.value
            isLoaded = true
        }
    }

    @ViewBuilder
    private func row(path: String, label: String) -> some View {
        Button {
            selection = path
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if selection == path {
                    Image(systemName: "checkmark")
                        .foregroundStyle(appAccent)
                }
            }
        }
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return paths }
        return paths.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// A vault's templates almost always live in a folder saying so, and that
    /// is the only thing anyone opens this list to find.
    private nonisolated static func templatesFirst(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.localizedCaseInsensitiveContains("template")
        let right = rhs.localizedCaseInsensitiveContains("template")
        if left != right { return left }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
