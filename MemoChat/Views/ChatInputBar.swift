import SwiftUI
import SwiftData

struct ChatInputBar: View {
    let activeDraft: Draft?
    let keyboardVisible: Bool
    let onCommit: () -> Void
    let onPlusTapped: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var inputText: String = ""
    @State private var textHeight: CGFloat = 36
    @StateObject private var speech = SpeechTranscriptionService()

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var horizontalPad: CGFloat { keyboardVisible ? 12 : 28 }
    private var bottomPad: CGFloat { keyboardVisible ? 10 : -10 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            plusButton

            inputPill
        }
        .padding(.horizontal, horizontalPad)
        .padding(.top, 8)
        .padding(.bottom, bottomPad)
        .animation(.easeOut(duration: 0.2), value: keyboardVisible)
        .onChange(of: inputText) { _, newText in saveText(newText) }
        .onChange(of: activeDraft?.id) { _, _ in inputText = activeDraft?.text ?? "" }
        .onChange(of: activeDraft?.text) { _, newText in
            let updated = newText ?? ""
            if inputText != updated { inputText = updated }
        }
        .onChange(of: speech.transcribedText) { _, newText in inputText = newText }
        .onAppear { inputText = activeDraft?.text ?? "" }
    }

    // Height of the pill (text area + top/bottom padding)
    private var pillHeight: CGFloat { textHeight + 14 }
    // Fixed single-line height so the plus button doesn't grow with multiline input
    private var singleLinePillHeight: CGFloat { 36 + 14 }

    // MARK: - Subviews

    private var plusButton: some View {
        Button { onPlusTapped() } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: singleLinePillHeight, height: singleLinePillHeight)
                .glassEffect(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var inputPill: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ChatTextInput(
                text: $inputText,
                height: $textHeight,
                placeholder: "Message"
            )
            .frame(height: textHeight)

            rightButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var rightButton: some View {
        if speech.isTranscribing {
            Button { speech.stopTranscription() } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else if canSend {
            Button { handleSend() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            Button { handleMic() } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func saveText(_ text: String) {
        guard let draft = activeDraft else { return }
        draft.text = text
        draft.updatedAt = Date()
        modelContext.saveOrAssert()
    }

    private func handleSend() {
        guard canSend else { return }
        onCommit()
        inputText = ""
    }

    private func handleMic() {
        Task {
            let authorized = await SpeechTranscriptionService.requestAuthorization()
            guard authorized else { return }
            speech.startTranscription()
        }
    }
}
