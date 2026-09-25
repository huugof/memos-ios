import SwiftUI

struct SettingsView: View {
    let onBack: () -> Void

    @State private var endpointBaseURL = AppSettings.endpointBaseURL
    @State private var token = KeychainTokenStore.getToken()
    @State private var allowInsecureHTTP = AppSettings.allowInsecureHTTP
    @State private var keepTextAfterSend = AppSettings.keepTextAfterSend
    @State private var markSentOnSuccess = AppSettings.markSentOnSuccess
    @State private var clearErrorOnEdit = AppSettings.clearErrorOnEdit
    @State private var quickCaptureMode = AppSettings.quickCaptureMode
    @State private var newNoteDelay = AppSettings.newNoteDelay
    @State private var showHistoryAfterSend = AppSettings.showHistoryAfterSend
    @State private var customTags = AppSettings.customTags.map { "#\($0)" }.joined(separator: " ")
    @State private var tokenStatus = ""
    @State private var showingDeleteTokenConfirmation = false

    init(onBack: @escaping () -> Void = {}) {
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Settings")
                    .font(.title2.weight(.bold))

                Spacer()

                Button(action: onBack) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                VaultSettingsSection()

                Section("Memos") {
                    TextField("https://example.com", text: $endpointBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onChange(of: endpointBaseURL) { _, value in
                            AppSettings.endpointBaseURL = value
                        }

                    if let endpointMessage {
                        Text(endpointMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("API Token") {
                    SecureField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    Button("Save Token") {
                        saveToken()
                    }
                    .disabled(trimmedToken.isEmpty)

                    Button("Delete Token", role: .destructive) {
                        showingDeleteTokenConfirmation = true
                    }

                    if !tokenStatus.isEmpty {
                        Text(tokenStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("#work #ideas #todo", text: $customTags, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onChange(of: customTags) { _, value in
                            AppSettings.customTags = Self.parseTags(value)
                        }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Suggested while typing a #tag, along with tags already in your notes.")
                }

                Section("Behavior") {
                    Toggle("Show history after sending", isOn: $showHistoryAfterSend)
                        .onChange(of: showHistoryAfterSend) { _, value in
                            AppSettings.showHistoryAfterSend = value
                        }

                    Toggle("Quick Capture Mode", isOn: $quickCaptureMode)
                        .onChange(of: quickCaptureMode) { _, value in
                            AppSettings.quickCaptureMode = value
                        }

                    if quickCaptureMode {
                        Picker("New Note After", selection: $newNoteDelay) {
                            ForEach(AppSettings.NewNoteDelay.allCases) { delay in
                                Text(delay.label).tag(delay)
                            }
                        }
                        .onChange(of: newNoteDelay) { _, value in
                            AppSettings.newNoteDelay = value
                        }
                    }

                    Toggle("Allow insecure HTTP", isOn: $allowInsecureHTTP)
                        .onChange(of: allowInsecureHTTP) { _, value in
                            AppSettings.allowInsecureHTTP = value
                        }

                    Toggle("Keep text after successful send", isOn: $keepTextAfterSend)
                        .onChange(of: keepTextAfterSend) { _, value in
                            AppSettings.keepTextAfterSend = value
                        }

                    Toggle("Mark as Sent on success", isOn: $markSentOnSuccess)
                        .onChange(of: markSentOnSuccess) { _, value in
                            AppSettings.markSentOnSuccess = value
                        }

                    Toggle("Clear error state on edit", isOn: $clearErrorOnEdit)
                        .onChange(of: clearErrorOnEdit) { _, value in
                            AppSettings.clearErrorOnEdit = value
                        }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            "Delete saved API token?",
            isPresented: $showingDeleteTokenConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Token", role: .destructive) {
                deleteToken()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var endpointMessage: String? {
        let trimmed = endpointBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Endpoint is required before sending."
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return "Endpoint URL is invalid."
        }

        if scheme == "http" && !allowInsecureHTTP {
            return "HTTP requires enabling Allow insecure HTTP."
        }

        if scheme != "https" && scheme != "http" {
            return "Endpoint must use https:// (or http:// when insecure mode is enabled)."
        }

        return nil
    }

    private func saveToken() {
        guard !trimmedToken.isEmpty else {
            tokenStatus = "Token cannot be empty"
            return
        }

        do {
            try KeychainTokenStore.setToken(trimmedToken)
            let stored = KeychainTokenStore.getToken()
            guard !stored.isEmpty else {
                tokenStatus = "Failed to save token"
                return
            }
            token = stored
            tokenStatus = "Token saved"
        } catch {
            tokenStatus = (error as? LocalizedError)?.errorDescription ?? "Failed to save token"
        }
    }

    private func deleteToken() {
        do {
            try KeychainTokenStore.deleteToken()
            token = ""
            tokenStatus = "Token deleted"
        } catch {
            tokenStatus = (error as? LocalizedError)?.errorDescription ?? "Failed to delete token"
        }
    }

    /// Space- or comma-separated, `#` optional; duplicates dropped, first spelling kept.
    private static func parseTags(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.drop(while: { $0 == "#" }) }
            .map { String($0.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
