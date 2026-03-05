import SwiftUI
import SwiftData

private enum DraftMenuTab: String, CaseIterable, Identifiable {
    case active = "Local"
    case server = "Server"

    var id: String { rawValue }
}

struct DraftMenuView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    let currentDraftID: UUID?
    let onSelectDraft: (Draft) -> Void
    let onCreateNewDraft: () -> Void
    let onSendDraft: (Draft) -> Void
    let onOpenSettings: () -> Void

    @State private var tab: DraftMenuTab = .active

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
                        topContentInset: serverContentTopInset
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
    }

    private var topChromeTopPadding: CGFloat { 26 }
    private var serverContentTopInset: CGFloat { 120 }
    private var serverHeaderGradientHeight: CGFloat { 170 }

    private var topChrome: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Drafts")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                if tab == .server {
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
