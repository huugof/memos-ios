import SwiftUI
import SwiftData

struct DraftMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Draft.updatedAt, order: .reverse) private var drafts: [Draft]

    let currentDraftID: UUID?
    let onSelectDraft: (Draft) -> Void
    let onCreateNewDraft: () -> Void

    @State private var scope: DraftScope = .active
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Memos")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 20)

                    Picker("Draft Scope", selection: $scope) {
                        ForEach(DraftScope.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal)

                List {
                    ForEach(filteredDrafts) { draft in
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
                .listStyle(.plain)
            }
            .padding(.top, 26)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: sideButtonWidth, height: controlHeight)
                    }
                    .foregroundStyle(controlForegroundColor)
                    .accessibilityLabel("Settings")

                    divider

                    Button {
                        onCreateNewDraft()
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .bold))
                            Text("New Note")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(width: middleButtonWidth, height: controlHeight)
                    }
                    .foregroundStyle(primaryActionColor)
                    .accessibilityLabel("New Draft")
                }
                .padding(6)
                .background(
                    Capsule(style: .continuous)
                        .fill(controlFillColor)
                )
                .shadow(color: controlShadowColor, radius: controlShadowRadius, x: 0, y: controlShadowY)
                .frame(maxWidth: .infinity)
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

    private var divider: some View {
        Rectangle()
            .fill(controlSeparatorColor)
            .frame(width: 1, height: 22)
    }

    private var controlHeight: CGFloat { 40 }
    private var sideButtonWidth: CGFloat { 72 }
    private var middleButtonWidth: CGFloat { 188 }

    private var controlFillColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.16)
        }
        return Color.black.opacity(0.08)
    }

    private var controlForegroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.92)
        }
        return Color.black.opacity(0.88)
    }

    private var controlSeparatorColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.12)
        }
        return Color.black.opacity(0.10)
    }

    private var controlShadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.12)
        }
        return Color.black.opacity(0.14)
    }

    private var controlShadowRadius: CGFloat {
        6
    }

    private var controlShadowY: CGFloat {
        2
    }

    private var primaryActionColor: Color {
        .blue
    }

    private func delete(_ draft: Draft) {
        DraftStore.delete(draft, in: modelContext)
    }

    private func duplicate(_ draft: Draft) {
        _ = DraftStore.duplicate(draft, in: modelContext)
    }
}
