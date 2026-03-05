import SwiftUI

@MainActor
final class ServerMemosStore: ObservableObject {
    @Published private(set) var memos: [ServerMemoSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published var errorMessage: String?
    @Published private(set) var isEditingSupported = true

    private var hasLoaded = false
    private var nextPageToken: String?
    private var reachedEnd = false
    private var lastRefreshAt: Date?

    func ensureInitialLoad() async {
        guard !hasLoaded else { return }
        await refresh(force: true)
    }

    func refreshIfStale(maxAge: TimeInterval = 60) async {
        let now = Date()
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < maxAge, hasLoaded {
            return
        }
        await refresh(force: true)
    }

    func refresh(force: Bool = true) async {
        if isLoading {
            return
        }
        if !force, hasLoaded {
            return
        }

        isLoading = true
        isLoadingNextPage = false
        reachedEnd = false
        nextPageToken = nil
        defer { isLoading = false }

        do {
            let page = try await MemosClient().fetchMemosPage(
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP,
                pageSize: 30,
                pageToken: nil
            )
            memos = page.memos
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
            errorMessage = nil
            hasLoaded = true
            lastRefreshAt = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadNextPageIfNeeded() async {
        guard !isLoading else { return }
        guard !isLoadingNextPage else { return }
        guard !reachedEnd else { return }
        guard let token = nextPageToken, !token.isEmpty else {
            reachedEnd = true
            return
        }

        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        do {
            let page = try await MemosClient().fetchMemosPage(
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP,
                pageSize: 30,
                pageToken: token
            )

            var seen = Set(memos.map(\.id))
            for memo in page.memos where !seen.contains(memo.id) {
                memos.append(memo)
                seen.insert(memo.id)
            }
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
            errorMessage = nil
            lastRefreshAt = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func canEdit(_ memo: ServerMemoSummary) -> Bool {
        isEditingSupported && memo.isEditable
    }

    func updateMemoContent(memoID: String, newContent: String) async throws {
        guard let index = memos.firstIndex(where: { $0.id == memoID }) else { return }
        let memo = memos[index]
        guard let resourceName = memo.resourceName else {
            throw MemosError.badResponse(400, "This note cannot be edited on this server.")
        }

        do {
            let updated = try await MemosClient().updateMemoContent(
                resourceName: resourceName,
                content: newContent,
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP
            )
            memos[index] = updated
            errorMessage = nil
            lastRefreshAt = Date()
        } catch let MemosError.badResponse(status, _) where status == 404 || status == 405 {
            isEditingSupported = false
            throw MemosError.badResponse(status, "This server does not support note editing.")
        } catch {
            throw error
        }
    }
}

struct ServerMemosSheetView: View {
    let showsHeader: Bool
    let topContentInset: CGFloat

    @EnvironmentObject private var store: ServerMemosStore
    @State private var editingMemo: ServerMemoSummary?
    @State private var editingContent = ""
    @State private var isSavingEdit = false
    @State private var editErrorMessage: String?

    init(showsHeader: Bool = true, topContentInset: CGFloat = 0) {
        self.showsHeader = showsHeader
        self.topContentInset = topContentInset
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    Text("Notes")
                        .font(.title2.weight(.bold))
                    Spacer()
                    Button {
                        Task {
                            await store.refresh(force: true)
                        }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoading)
                    .accessibilityLabel("Refresh")
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !store.isEditingSupported {
                        Text("Server note editing is unavailable for this server version.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 6)
                    }

                    if store.isLoading && store.memos.isEmpty {
                        loadingStateView
                    } else if let errorMessage = store.errorMessage, store.memos.isEmpty {
                        errorStateView(message: errorMessage)
                    } else if store.memos.isEmpty {
                        emptyStateView
                    } else {
                        memoRows
                    }
                }
                .padding(.bottom, 16)
            }
            .refreshable {
                await store.refresh(force: true)
            }
            .padding(.top, contentTopInset)
            .task {
                await store.ensureInitialLoad()
            }
        }
        .sheet(item: $editingMemo) { memo in
            NavigationStack {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $editingContent)
                        .padding(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .frame(maxHeight: .infinity)

                    if let editErrorMessage, !editErrorMessage.isEmpty {
                        Text(editErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .navigationTitle("Edit Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismissEditing()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSavingEdit ? "Saving…" : "Save") {
                            saveEdit(memoID: memo.id)
                        }
                        .disabled(!canSaveEdit(for: memo))
                    }
                }
            }
        }
    }

    private var loadingStateView: some View {
        ProgressView("Loading notes…")
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }

    @ViewBuilder
    private func errorStateView(message: String) -> some View {
        VStack(spacing: 12) {
            Text("Unable to load notes")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await store.refresh(force: true)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Notes",
            systemImage: "tray",
            description: Text("Pull to refresh after configuring your endpoint and token.")
        )
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder
    private var memoRows: some View {
        ForEach(store.memos.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 8) {
                Text(store.memos[index].content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if let updatedAt = store.memos[index].updatedAt {
                        Text(updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if store.canEdit(store.memos[index]) {
                        Text("Tap to edit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                let memo = store.memos[index]
                guard store.canEdit(memo) else { return }
                beginEditing(memo)
            }
            .onAppear {
                guard index >= store.memos.count - 5 else { return }
                Task {
                    await store.loadNextPageIfNeeded()
                }
            }

            if index < store.memos.count - 1 {
                Divider()
                    .padding(.horizontal, 14)
            }
        }

        if store.isLoadingNextPage {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }
    }

    private func beginEditing(_ memo: ServerMemoSummary) {
        editingMemo = memo
        editingContent = memo.content
        editErrorMessage = nil
    }

    private func dismissEditing() {
        editingMemo = nil
        editingContent = ""
        editErrorMessage = nil
        isSavingEdit = false
    }

    private func canSaveEdit(for memo: ServerMemoSummary) -> Bool {
        guard !isSavingEdit else { return false }
        let trimmed = editingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != memo.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveEdit(memoID: String) {
        let trimmed = editingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSavingEdit = true
        editErrorMessage = nil

        Task {
            do {
                try await store.updateMemoContent(memoID: memoID, newContent: trimmed)
                dismissEditing()
            } catch {
                isSavingEdit = false
                editErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var contentTopInset: CGFloat {
        if showsHeader {
            return 0
        }
        return max(0, topContentInset)
    }
}
