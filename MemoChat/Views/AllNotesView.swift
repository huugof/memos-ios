import SwiftUI
import SwiftData

let appAccent = Color(red: 1.0, green: 0.78, blue: 0.0)

struct AllNotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Draft.createdAt, order: .forward) private var allDrafts: [Draft]
    @Query private var allEditDrafts: [ServerMemoEditDraft]
    @Query private var allDeleteTasks: [ServerMemoDeleteTask]
    @EnvironmentObject private var serverMemosStore: ServerMemosStore
    @EnvironmentObject private var serverDeleteQueue: ServerMemoDeleteQueueController
    @EnvironmentObject private var pinnedStore: PinnedNotesStore
    @StateObject private var keyboard = KeyboardStateObserver()

    @State private var isSearchActive = false
    @State private var searchText = ""
    @State private var searchFilter: NoteSearchFilter? = nil
    @State private var filterByTags = false
    @State private var filterByAttachments = false
    @State private var filterByChecklists = false
    @State private var showMenu = false
    @State private var showSettings = false
    @State private var showAttachmentsBrowser = false
    @State private var bottomBarID = 0

    @FocusState private var searchFocused: Bool

    private var hiddenMemoIDs: Set<String> {
        Set(allDeleteTasks.filter { $0.deleteState != .resolved }.map { $0.memoID })
    }

    private var allNotes: [UnifiedNote] {
        UnifiedNote.merge(
            drafts: allDrafts,
            memos: serverMemosStore.memos,
            editDrafts: allEditDrafts,
            hiddenMemoIDs: hiddenMemoIDs
        )
    }

    private var displayedNotes: [UnifiedNote] {
        var notes = allNotes
        if filterByTags        { notes = notes.filter { !$0.tags.isEmpty } }
        if filterByAttachments { notes = notes.filter { $0.hasAttachments } }
        if filterByChecklists  { notes = notes.filter { $0.hasChecklists } }
        return notes
    }

    private var pinnedNotes: [UnifiedNote] {
        displayedNotes.filter { pinnedStore.isPinned($0.id) }
    }

    private var unpinnedGroups: [NoteDateGrouping.Group] {
        NoteDateGrouping.group(displayedNotes.filter { !pinnedStore.isPinned($0.id) })
    }

    private var topTags: [String] {
        var counts: [String: Int] = [:]
        for note in allNotes {
            for tag in note.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12).map(\.key)
    }

    // Narrower (more inset) when resting at the curved bottom edge;
    // wider (less inset) when floating above the keyboard.
    private var barHorizontalPadding: CGFloat {
        keyboard.isVisible ? 8 : 28
    }

    private var barVerticalPadding: CGFloat {
        keyboard.isVisible ? 10 : 6
    }

    var body: some View {
        ZStack {
            if isSearchActive {
                NoteSearchView(
                    searchText: $searchText,
                    searchFilter: $searchFilter,
                    notes: allNotes,
                    topTags: topTags,
                    isLoadingMore: !serverMemosStore.reachedEnd
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            } else {
                notesList
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            }
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color(uiColor: .systemGroupedBackground).opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar.id(bottomBarID)
        }
        .navigationTitle(isSearchActive ? "" : (activeFilterLabel ?? "All Notes"))
        .navigationBarTitleDisplayMode(activeFilterLabel != nil ? .inline : .large)
        .toolbar(isSearchActive ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(.primary)
            }
        }
        .sheet(isPresented: $showMenu) {
            NotesMenuSheet(
                onRefresh: { Task { await serverMemosStore.loadAllPages() } },
                onShowAttachments: { showAttachmentsBrowser = true },
                onSettings: { showSettings = true }
            )
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAttachmentsBrowser) { attachmentsBrowserSheet }
        .onAppear {
            searchFocused = false
            bottomBarID += 1  // force safeAreaInset re-render on navigation return
        }
        .onChange(of: isSearchActive) { _, active in
            if active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
                if !serverMemosStore.reachedEnd {
                    Task { await serverMemosStore.loadRemainingPages() }
                }
            }
        }
    }

    // MARK: Notes list

    private var notesList: some View {
        List {
            if let msg = serverMemosStore.errorMessage {
                Section {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if activeFilterLabel != nil {
                Section {
                    filterChip.listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }

            if pinnedNotes.isEmpty && unpinnedGroups.isEmpty && !serverMemosStore.isLoading {
                Section {
                    Text(activeFilterLabel != nil
                         ? "No notes match this filter."
                         : "No notes yet. Tap the compose button below to create your first note.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if !pinnedNotes.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedNotes) { note in noteRow(for: note) }
                }
            }

            ForEach(unpinnedGroups) { group in
                Section(group.header) {
                    ForEach(group.notes) { note in noteRow(for: note) }
                }
            }

            // Pagination sentinel — triggers lazy-load of older pages when scrolled into view
            if !serverMemosStore.reachedEnd {
                Section {
                    Color.clear
                        .frame(height: 1)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .task { await serverMemosStore.loadNextPageIfNeeded() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await serverMemosStore.loadAllPages() }
        .overlay(alignment: .center) {
            if serverMemosStore.isLoading && pinnedNotes.isEmpty && unpinnedGroups.isEmpty { ProgressView() }
        }
    }

    @ViewBuilder
    private func noteRow(for note: UnifiedNote) -> some View {
        NavigationLink(value: NotesRoute.editor(note.editorTarget)) {
            NoteRowView(note: note)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteNote(note) } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    // MARK: Bottom bar

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.primary)
                .font(.system(size: 16, weight: .medium))

            // Active filter chip
            if isSearchActive, let filter = searchFilter {
                HStack(spacing: 4) {
                    Image(systemName: filter.icon).font(.caption2.weight(.semibold))
                    Text(filter.label).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                    Button { searchFilter = nil } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(appAccent.opacity(0.18), in: Capsule())
                .foregroundStyle(appAccent)
            }

            if isSearchActive {
                TextField(searchFilter != nil ? "Narrow results…" : "Search", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
            } else {
                Text("Search").foregroundStyle(.tertiary)
            }

            Spacer()

            if isSearchActive && !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "mic.fill")
                    .foregroundStyle(isSearchActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .font(.system(size: 14))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassCapsule()
        .contentShape(Capsule())
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Search pill — tappable when inactive, live input when active
            if isSearchActive {
                searchPill
            } else {
                Button { isSearchActive = true } label: { searchPill }
                    .buttonStyle(.plain)
            }

            // Right button
            if isSearchActive {
                Button { dismissSearch() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .glassCircle()
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                NavigationLink(value: NotesRoute.editor(.newNote)) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .glassCircle()
                }
                .tint(.primary)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, barHorizontalPadding)
        .padding(.vertical, barVerticalPadding)
        .animation(.spring(duration: 0.25), value: isSearchActive)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, Color(uiColor: .systemGroupedBackground).opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160)
            .offset(y: 44)
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func dismissSearch() {
        searchText = ""
        searchFilter = nil
        isSearchActive = false
        searchFocused = false
    }

    // MARK: Filter chip

    private var activeFilterLabel: String? {
        if filterByTags { return "Has Tags" }
        if filterByAttachments { return "Has Attachments" }
        if filterByChecklists { return "Todos" }
        return nil
    }

    private var activeFilterIcon: String {
        if filterByTags { return "tag" }
        if filterByAttachments { return "paperclip" }
        return "checklist"
    }

    @ViewBuilder
    private var filterChip: some View {
        if let label = activeFilterLabel {
            HStack(spacing: 8) {
                Image(systemName: activeFilterIcon).font(.caption)
                Text(label).font(.caption.weight(.medium))
                Button {
                    filterByTags = false; filterByAttachments = false; filterByChecklists = false
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    // MARK: Attachments browser

    private var attachmentsBrowserSheet: some View {
        NavigationStack {
            List(allNotes.filter { $0.hasAttachments }) { note in
                NavigationLink(value: NotesRoute.editor(note.editorTarget)) {
                    NoteRowView(note: note)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showAttachmentsBrowser = false }
                }
            }
        }
    }

    // MARK: Delete

    private func deleteNote(_ note: UnifiedNote) {
        switch note {
        case .local(let draft):
            DraftStore.delete(draft, in: modelContext)
        case .server(let memo, _):
            serverMemosStore.removeMemo(memoID: memo.id)
            _ = serverDeleteQueue.enqueue(
                memoID: memo.id,
                resourceName: memo.resourceName ?? memo.id,
                in: modelContext
            )
        }
    }
}

// MARK: Liquid glass helpers

extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }

    /// Use inside system nav bar toolbar items. On iOS 26 the nav bar itself is glass,
    /// so we skip the explicit glassEffect to avoid double-glass nesting.
    @ViewBuilder
    func glassToolbarCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
}
