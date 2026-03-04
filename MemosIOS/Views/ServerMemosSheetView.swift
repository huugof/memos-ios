import SwiftUI

struct ServerMemosSheetView: View {
    let showsHeader: Bool
    let topContentInset: CGFloat

    @State private var memos: [ServerMemoSummary] = []
    @State private var isLoading = false
    @State private var isLoadingNextPage = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var nextPageToken: String?
    @State private var reachedEnd = false

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
                            await loadInitialMemos()
                        }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh")
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            Group {
                if isLoading && memos.isEmpty {
                    ProgressView("Loading notes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, memos.isEmpty {
                    VStack(spacing: 12) {
                        Text("Unable to load notes")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task {
                                await loadInitialMemos()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if memos.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "tray",
                        description: Text("Pull to refresh after configuring your endpoint and token.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(memos.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(memos[index].content)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    if let updatedAt = memos[index].updatedAt {
                                        Text(updatedAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .onAppear {
                                    guard index >= memos.count - 5 else { return }
                                    Task {
                                        await loadNextPageIfNeeded()
                                    }
                                }

                                if index < memos.count - 1 {
                                    Divider()
                                        .padding(.horizontal, 14)
                                }
                            }

                            if isLoadingNextPage {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 10)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .refreshable {
                        await loadInitialMemos()
                    }
                }
            }
            .padding(.top, contentTopInset)
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await loadInitialMemos()
            }
        }
    }

    private var contentTopInset: CGFloat {
        if showsHeader {
            return 0
        }
        return max(0, topContentInset)
    }

    @MainActor
    private func loadInitialMemos() async {
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
        } catch {
            if let localizedError = error as? LocalizedError,
               let description = localizedError.errorDescription {
                errorMessage = description
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadNextPageIfNeeded() async {
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
        } catch {
            if let localizedError = error as? LocalizedError,
               let description = localizedError.errorDescription {
                errorMessage = description
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
