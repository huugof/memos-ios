import SwiftUI
import SwiftData

struct DraftMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    let currentDraftID: UUID?
    let onSelectDraft: (Draft) -> Void
    let onCreateNewDraft: () -> Void

    @State private var scope: DraftScope = .active
    @State private var showingSettings = false
    @State private var isBulkMode = false
    @State private var selectedDraftIDs: Set<UUID> = []
    @State private var isPerformingBulkAction = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Draft Scope", selection: $scope) {
                    ForEach(DraftScope.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                List {
                    ForEach(filteredDrafts) { draft in
                        if isBulkMode {
                            Button {
                                toggleSelection(for: draft)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedDraftIDs.contains(draft.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(selectedDraftIDs.contains(draft.id) ? .blue : .secondary)
                                    DraftRowView(draft: draft)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                onSelectDraft(draft)
                                dismiss()
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

                                if scope == .active {
                                    Button {
                                        Task {
                                            _ = await DraftSendService.send(draft: draft, in: modelContext)
                                        }
                                    } label: {
                                        Label("Send", systemImage: "paperplane.fill")
                                    }
                                    .tint(.blue)
                                    .disabled(!draft.canSend)
                                }
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
                }
                .listStyle(.plain)
            }
            .padding(.top, 50)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()

                    HStack(spacing: 0) {
                        if isBulkMode {
                            pillButton(symbol: "paperplane.fill", accessibilityLabel: "Bulk Send") {
                                Task {
                                    await bulkSendSelected()
                                }
                            }
                            .disabled(selectedSendableDrafts.isEmpty || isPerformingBulkAction)
                            .foregroundStyle(selectedSendableDrafts.isEmpty ? Color.secondary : Color.blue)

                            separator

                            pillButton(symbol: "xmark", accessibilityLabel: "Bulk Delete") {
                                bulkDeleteSelected()
                            }
                            .disabled(selectedDrafts.isEmpty || isPerformingBulkAction)
                            .foregroundStyle(selectedDrafts.isEmpty ? Color.secondary : Color.blue)

                            separator
                        }

                        pillButton(symbol: isBulkMode ? "circle.fill" : "circle", accessibilityLabel: "Bulk Actions") {
                            toggleBulkMode()
                        }
                        .foregroundStyle(isBulkMode ? Color.blue : Color.primary)

                        separator

                        pillButton(symbol: "plus", accessibilityLabel: "New Draft") {
                            onCreateNewDraft()
                            dismiss()
                        }

                        separator

                        pillButton(symbol: "gearshape", accessibilityLabel: "Settings") {
                            showingSettings = true
                        }
                    }
                    .padding(4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 4)
                }
                .padding(.leading, 24)
                .padding(.trailing, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }

    private var filteredDrafts: [Draft] {
        DraftStore.filteredDrafts(drafts, scope: scope)
    }

    private var selectedDrafts: [Draft] {
        drafts.filter { selectedDraftIDs.contains($0.id) }
    }

    private var selectedSendableDrafts: [Draft] {
        selectedDrafts.filter { !$0.isArchived && $0.canSend }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
    }

    private func pillButton(symbol: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(accessibilityLabel)
    }

    private func toggleBulkMode() {
        isBulkMode.toggle()
        if !isBulkMode {
            selectedDraftIDs.removeAll()
        }
    }

    private func toggleSelection(for draft: Draft) {
        if selectedDraftIDs.contains(draft.id) {
            selectedDraftIDs.remove(draft.id)
        } else {
            selectedDraftIDs.insert(draft.id)
        }
    }

    private func bulkSendSelected() async {
        let targets = selectedSendableDrafts
        guard !targets.isEmpty else { return }

        isPerformingBulkAction = true
        defer {
            isPerformingBulkAction = false
            selectedDraftIDs.removeAll()
            isBulkMode = false
        }

        for draft in targets {
            _ = await DraftSendService.send(draft: draft, in: modelContext)
        }
    }

    private func bulkDeleteSelected() {
        let targets = selectedDrafts
        guard !targets.isEmpty else { return }

        DraftStore.delete(targets, in: modelContext)

        selectedDraftIDs.removeAll()
        isBulkMode = false
    }

    private func delete(_ draft: Draft) {
        DraftStore.delete(draft, in: modelContext)
    }

    private func duplicate(_ draft: Draft) {
        _ = DraftStore.duplicate(draft, in: modelContext)
    }
}
