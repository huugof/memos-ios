import SwiftUI
import SwiftData
import UIKit

struct ChatInputBar: View {
    let activeDraft: Draft?
    let keyboardVisible: Bool
    var focusTrigger: UUID? = nil
    let onCommit: () -> Void
    let onPlusTapped: () -> Void
    var onImageSelected: ((UIImage) -> Void)? = nil
    var pendingImages: [PendingImage] = []
    var onRemoveImage: ((UUID) -> Void)? = nil
    var pendingFiles: [PendingFile] = []
    var onRemoveFile: ((UUID) -> Void)? = nil
    var tagSuggestions: [String] = []

    @Environment(\.modelContext) private var modelContext
    @State private var inputText: String = ""
    @State private var textHeight: CGFloat = 36
    @State private var preTranscriptionText: String = ""
    @StateObject private var speech = SpeechTranscriptionService()

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || pendingImages.contains { $0.uploadedURL != nil }
        || pendingFiles.contains { $0.uploadedURL != nil }
    }

    private var horizontalPad: CGFloat { keyboardVisible ? 12 : 28 }
    private var bottomPad: CGFloat { keyboardVisible ? 10 : -10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pendingImages.isEmpty {
                pendingImageStrip
            }
            if !pendingFiles.isEmpty {
                pendingFileStrip
            }
            HStack(alignment: .bottom, spacing: 10) {
                plusButton

                inputPill
            }
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
        .onChange(of: speech.isTranscribing) { _, active in
            if active { preTranscriptionText = inputText }
        }
        .onChange(of: speech.transcribedText) { _, newText in
            guard !newText.isEmpty else { return }
            let base = preTranscriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            inputText = base.isEmpty ? newText : base + " " + newText
        }
        .onAppear { inputText = activeDraft?.text ?? "" }
    }

    // Height of the pill (text area + top/bottom padding)
    private var pillHeight: CGFloat { textHeight + 14 }
    // Fixed single-line height so the plus button doesn't grow with multiline input
    private var singleLinePillHeight: CGFloat { 36 + 14 }

    // MARK: - Subviews

    private var pendingImageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { pending in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: pending.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if pending.isUploading {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.black.opacity(0.3))
                                    ProgressView().tint(.white)
                                }
                            }
                        Button { onRemoveImage?(pending.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.leading, singleLinePillHeight + 10) // align with input pill (past plus button)
            .padding(.top, 4)
        }
    }

    private var pendingFileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingFiles) { pending in
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                            Text(pending.filename)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(height: 40)
                        .background(Color(uiColor: .tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            if pending.isUploading {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.black.opacity(0.3))
                                ProgressView().tint(.white)
                            }
                        }
                        Button { onRemoveFile?(pending.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.leading, singleLinePillHeight + 10)
            .padding(.top, 4)
        }
    }

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
                placeholder: "Message",
                tagSuggestions: tagSuggestions,
                focusTrigger: focusTrigger,
                onImagePasted: onImageSelected
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
        textHeight = 36
    }

    private func handleMic() {
        Task {
            let authorized = await SpeechTranscriptionService.requestAuthorization()
            guard authorized else { return }
            speech.startTranscription()
        }
    }
}

