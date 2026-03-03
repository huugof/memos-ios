import SwiftUI
import SwiftData

struct DraftEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var draft: Draft

    let onBack: (Draft) -> Void
    let onNewNote: (Draft) -> Void
    let onSendSuccess: (Draft) -> Void

    @State private var draftText: String
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isEditorFocused = true
    @State private var focusRequestID = UUID()

    init(
        draft: Draft,
        onBack: @escaping (Draft) -> Void = { _ in },
        onNewNote: @escaping (Draft) -> Void = { _ in },
        onSendSuccess: @escaping (Draft) -> Void = { _ in }
    ) {
        self.draft = draft
        self.onBack = onBack
        self.onNewNote = onNewNote
        self.onSendSuccess = onSendSuccess
        _draftText = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = draft.lastError, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.primary)

                        Button("Retry Send") {
                            sendDraft()
                        }
                        .font(.footnote.weight(.semibold))
                    }

                    Spacer()
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            NoteTextView(text: $draftText, isFocused: $isEditorFocused, focusRequestID: focusRequestID)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .onChange(of: draftText) { _, _ in
                    scheduleAutosave()
                }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()

                HStack(spacing: 0) {
                    Button {
                        sendDraft()
                    } label: {
                        if draft.sendState == .sending {
                            ProgressView()
                                .tint(.primary)
                                .frame(width: 44, height: 44)
                        } else {
                            Image(systemName: "paperplane")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                    }
                    .foregroundStyle(canSendCurrentText ? .primary : .secondary)
                    .disabled(!canSendCurrentText)
                    .accessibilityLabel("Send")

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 22)

                    Button {
                        handleNewNote()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("New Note")

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 22)

                    Button {
                        handleBack()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Menu")
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
        .onAppear {
            isEditorFocused = true
            focusRequestID = UUID()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                flushPendingAutosave()
            }
        }
        .onChange(of: draft.id) { _, _ in
            // Reset local editor buffer when navigation switches to a different draft.
            autosaveTask?.cancel()
            draftText = draft.text
            isEditorFocused = true
            focusRequestID = UUID()
        }
        .onDisappear {
            flushPendingAutosave()
        }
    }

    private var canSendCurrentText: Bool {
        if draft.sendState == .sending {
            return false
        }

        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        if let lastSentAt = draft.lastSentAt, draft.updatedAt <= lastSentAt, draftText == draft.text {
            return false
        }

        return true
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let latestText = draftText

        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run {
                applyDraftChanges(newText: latestText)
            }
        }
    }

    private func flushPendingAutosave() {
        autosaveTask?.cancel()
        applyDraftChanges(newText: draftText)
    }

    private func applyDraftChanges(newText: String) {
        guard draft.text != newText else {
            return
        }

        draft.text = newText
        draft.updatedAt = Date()

        if AppSettings.clearErrorOnEdit {
            draft.lastError = nil
        }

        if draft.lastSentAt != nil {
            draft.sendState = .idle
            draft.isArchived = false
        }

        modelContext.saveOrAssert()
    }

    private func handleBack() {
        flushPendingAutosave()
        isEditorFocused = false
        onBack(draft)
    }

    private func handleNewNote() {
        flushPendingAutosave()
        isEditorFocused = false
        onNewNote(draft)
    }

    private func sendDraft() {
        flushPendingAutosave()

        Task {
            let outcome = await DraftSendService.send(draft: draft, in: modelContext)
            draftText = draft.text

            if case .success = outcome {
                isEditorFocused = false
                onSendSuccess(draft)
            }
        }
    }
}
