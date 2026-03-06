import SwiftUI
import SwiftData

enum DraftMenuTab: String, CaseIterable, Identifiable {
    case active = "Local"
    case server = "Server"

    var id: String { rawValue }
}

struct DraftMenuView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]
    @Query(sort: \ServerMemoEditDraft.updatedAt, order: .reverse) private var serverEditDrafts: [ServerMemoEditDraft]

    @Binding var tab: DraftMenuTab

    let currentDraftID: UUID?
    let onSelectDraft: (Draft) -> Void
    let onCreateNewDraft: () -> Void
    let onSendDraft: (Draft) -> Void
    let onSelectServerMemo: (ServerMemoSummary) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            switch tab {
            case .active:
                VStack(spacing: 12) {
                    topChrome
                        .padding(.top, topChromeTopPadding)
                    activeDraftList
                }
            case .server:
                ZStack(alignment: .top) {
                    ServerMemosSheetView(
                        showsHeader: false,
                        topContentInset: serverContentTopInset,
                        onSelectMemo: { memo in
                            onSelectServerMemo(memo)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    topChrome
                        .padding(.top, topChromeTopPadding)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .background(alignment: .top) {
                            LinearGradient(
                                colors: [
                                    Color(uiColor: .systemBackground).opacity(0.98),
                                    Color(uiColor: .systemBackground).opacity(0.92),
                                    Color(uiColor: .systemBackground).opacity(0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: serverHeaderGradientHeight)
                            .allowsHitTesting(false)
                        }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard tab == .server else { return }
            Task {
                await serverMemosStore.refreshIfStale(maxAge: 10)
            }
        }
        .onChange(of: tab) { _, newTab in
            guard newTab == .server else { return }
            Task {
                await serverMemosStore.refreshIfStale(maxAge: 10)
            }
        }
    }

    private var topChromeTopPadding: CGFloat { 26 }
    private var serverContentTopInset: CGFloat { 120 }
    private var serverHeaderGradientHeight: CGFloat { 170 }
    private var hasPendingServerSyncWork: Bool {
        serverEditDrafts.contains { $0.saveState == .pending || $0.saveState == .saving }
    }
    private var isServerSyncing: Bool {
        serverMemosStore.isLoading
            || serverMemosStore.isLoadingNextPage
            || hasPendingServerSyncWork
            || (serverMemosStore.lastRefreshAt == nil && serverMemosStore.errorMessage == nil)
    }
    private var serverSyncStatusLabel: String {
        if isServerSyncing {
            return "Syncing"
        }
        if serverMemosStore.errorMessage != nil {
            return "Out of date"
        }
        return "Up to date"
    }
    private var serverSyncStatusColor: Color {
        if isServerSyncing {
            return .secondary
        }
        if serverMemosStore.errorMessage != nil {
            return .orange
        }
        return .green
    }

    private var topChrome: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Drafts")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                if tab == .server {
                    Text(serverSyncStatusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(serverSyncStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(serverSyncStatusColor.opacity(0.14), in: Capsule())

                    Button {
                        Task {
                            await serverMemosStore.refresh(force: true)
                        }
                    } label: {
                        if serverMemosStore.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh Server Notes")
                }

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 20)

            Picker("Draft Source", selection: $tab) {
                ForEach(DraftMenuTab.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
    }

    private var activeDraftList: some View {
        List {
            Button(action: onCreateNewDraft) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)

                    Text("New Note")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            ForEach(activeDrafts) { draft in
                Button {
                    onSelectDraft(draft)
                } label: {
                    HStack(spacing: 10) {
                        DraftRowView(draft: draft)
                        if draft.id == currentDraftID {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        delete(draft)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        onSendDraft(draft)
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .tint(.blue)
                    .disabled(!draft.canSend)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        duplicate(draft)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .tint(.orange)
                }
            }
        }
        .listStyle(.plain)
    }

    private var activeDrafts: [Draft] {
        drafts.filter { !$0.isArchived }
    }

    private func delete(_ draft: Draft) {
        DraftStore.delete(draft, in: modelContext)
    }

    private func duplicate(_ draft: Draft) {
        _ = DraftStore.duplicate(draft, in: modelContext)
    }
}
