import SwiftUI
import UIKit

/// A plain-text, auto-growing UITextView wrapper for the chat input bar.
/// Grows from 1 line up to `maxLines` lines, then scrolls internally.
struct ChatTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String = "Message"
    var maxLines: Int = 18
    var tagSuggestions: [String] = []
    var focusTrigger: UUID? = nil
    var onSubmit: (() -> Void)? = nil
    var onImagePasted: ((UIImage) -> Void)? = nil

    func makeUIView(context: Context) -> PasteAwareTextView {
        let tv = PasteAwareTextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.showsVerticalScrollIndicator = false
        tv.autocorrectionType = .yes
        tv.autocapitalizationType = .sentences
        tv.returnKeyType = .default
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.onImagePasted = onImagePasted
        context.coordinator.configureCompletionLabel(in: tv)
        return tv
    }

    func updateUIView(_ tv: PasteAwareTextView, context: Context) {
        if tv.text != text {
            tv.text = text
        }
        tv.onImagePasted = onImagePasted
        context.coordinator.updateTagSuggestions(tagSuggestions)
        context.coordinator.updatePlaceholder(in: tv, text: text, placeholder: placeholder)
        recalculateHeight(for: tv)
        context.coordinator.refreshTagPreview(in: tv)
        if let trigger = focusTrigger, context.coordinator.lastFocusTrigger != trigger {
            context.coordinator.lastFocusTrigger = trigger
            DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        }
    }

    private func recalculateHeight(for tv: UITextView) {
        let lineHeight = tv.font?.lineHeight ?? 20
        let maxHeight = lineHeight * CGFloat(maxLines) + tv.textContainerInset.top + tv.textContainerInset.bottom
        let fittingSize = tv.sizeThatFits(CGSize(width: tv.frame.width, height: .greatestFiniteMagnitude))
        let newHeight = min(fittingSize.height, maxHeight)
        let shouldScroll = fittingSize.height > maxHeight
        if abs(height - newHeight) > 0.5 { height = newHeight }
        if tv.isScrollEnabled != shouldScroll { tv.isScrollEnabled = shouldScroll }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatTextInput
        private var placeholderLabel: UILabel?
        private let completionLabel = UILabel()
        private var normalizedTagSuggestions: [String] = []
        var lastFocusTrigger: UUID? = nil

        init(_ parent: ChatTextInput) {
            self.parent = parent
        }

        // MARK: - Completion label setup

        func configureCompletionLabel(in tv: UITextView) {
            completionLabel.font = UIFont.preferredFont(forTextStyle: .body)
            completionLabel.textColor = UIColor.tertiaryLabel
            completionLabel.backgroundColor = .clear
            completionLabel.isUserInteractionEnabled = false
            completionLabel.isHidden = true
            tv.addSubview(completionLabel)
        }

        // MARK: - Tag suggestions

        func updateTagSuggestions(_ tags: [String]) {
            var seen = Set<String>()
            normalizedTagSuggestions = tags.compactMap { sanitizeTag($0) }.filter { tag in
                let key = tag.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
        }

        private func sanitizeTag(_ raw: String) -> String? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("#") { value.removeFirst() }
            guard !value.isEmpty else { return nil }
            guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
            return value
        }

        private func isTagCharacter(_ scalar: UnicodeScalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || scalar.value == 95 || scalar.value == 45
        }

        // MARK: - Tag completion detection

        private struct TagCompletion {
            let tag: String
            let suffix: String
            let caretLocation: Int
        }

        private func currentTagCompletion(in text: String, caretLocation: Int) -> TagCompletion? {
            guard !normalizedTagSuggestions.isEmpty else { return nil }
            let nsText = text as NSString
            guard caretLocation >= 0, caretLocation <= nsText.length else { return nil }

            var hashLocation: Int?
            var scan = caretLocation
            while scan > 0 {
                let previous = nsText.substring(with: NSRange(location: scan - 1, length: 1))
                if previous == "#" {
                    hashLocation = scan - 1
                    break
                }
                guard let scalar = previous.unicodeScalars.first, isTagCharacter(scalar) else { return nil }
                scan -= 1
            }

            guard let hashLocation else { return nil }

            if hashLocation > 0 {
                let leading = nsText.substring(with: NSRange(location: hashLocation - 1, length: 1))
                if let scalar = leading.unicodeScalars.first, isTagCharacter(scalar) { return nil }
            }

            if caretLocation < nsText.length {
                let trailing = nsText.substring(with: NSRange(location: caretLocation, length: 1))
                if let scalar = trailing.unicodeScalars.first, isTagCharacter(scalar) { return nil }
            }

            let prefixRange = NSRange(location: hashLocation + 1, length: caretLocation - hashLocation - 1)
            let prefix = nsText.substring(with: prefixRange)
            guard !prefix.isEmpty else { return nil }

            let lowerPrefix = prefix.lowercased()
            for candidate in normalizedTagSuggestions {
                let lowerCandidate = candidate.lowercased()
                guard lowerCandidate.hasPrefix(lowerPrefix), lowerCandidate != lowerPrefix else { continue }
                guard candidate.count >= prefix.count else { continue }
                let suffix = String(candidate.dropFirst(prefix.count))
                return TagCompletion(tag: candidate, suffix: suffix, caretLocation: caretLocation)
            }
            return nil
        }

        // MARK: - Tag preview display

        func refreshTagPreview(in textView: UITextView) {
            guard textView.selectedRange.length == 0 else { hideTagPreview(); return }
            let currentText = textView.text ?? ""
            let caretLocation = textView.selectedRange.location
            guard let completion = currentTagCompletion(in: currentText, caretLocation: caretLocation),
                  let caretPosition = textView.position(from: textView.beginningOfDocument, offset: completion.caretLocation)
            else {
                hideTagPreview()
                return
            }

            completionLabel.text = completion.suffix
            completionLabel.sizeToFit()
            let caretRect = textView.caretRect(for: caretPosition)
            var frame = completionLabel.frame
            frame.origin.x = min(caretRect.maxX + 1, textView.bounds.width - frame.width - 4)
            frame.origin.y = caretRect.minY + max(0, (caretRect.height - frame.height) / 2)
            completionLabel.frame = frame
            completionLabel.isHidden = false
        }

        func hideTagPreview() {
            completionLabel.isHidden = true
        }

        // MARK: - Placeholder

        func updatePlaceholder(in tv: UITextView, text: String, placeholder: String) {
            if placeholderLabel == nil {
                let label = UILabel()
                label.font = tv.font
                label.textColor = .placeholderText
                label.numberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                tv.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: tv.textContainerInset.left + tv.textContainer.lineFragmentPadding),
                    label.topAnchor.constraint(equalTo: tv.topAnchor, constant: tv.textContainerInset.top)
                ])
                placeholderLabel = label
            }
            placeholderLabel?.text = placeholder
            placeholderLabel?.isHidden = !text.isEmpty
        }

        // MARK: - UITextViewDelegate

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            parent.recalculateHeight(for: tv)
            placeholderLabel?.isHidden = !tv.text.isEmpty
            refreshTagPreview(in: tv)
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            refreshTagPreview(in: tv)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            let currentText = textView.text ?? ""

            // Accept tag completion on space or return
            if range.length == 0,
               textView.markedTextRange == nil,
               (replacement == " " || replacement == "\n"),
               let completion = currentTagCompletion(in: currentText, caretLocation: range.location),
               let swiftRange = Range(range, in: currentText) {
                let completedText = currentText.replacingCharacters(in: swiftRange, with: completion.suffix)
                let completedCaret = range.location + (completion.suffix as NSString).length
                AppSettings.recentAcceptedTags = {
                    var tags = AppSettings.recentAcceptedTags
                    tags.removeAll { $0.compare(completion.tag, options: .caseInsensitive) == .orderedSame }
                    tags.insert(completion.tag, at: 0)
                    return Array(tags.prefix(100))
                }()

                if replacement == " " {
                    let withSpace = (completedText as NSString).replacingCharacters(
                        in: NSRange(location: completedCaret, length: 0), with: " "
                    )
                    textView.text = withSpace
                    parent.text = withSpace
                    let cursorOffset = completedCaret + 1
                    if let pos = textView.position(from: textView.beginningOfDocument, offset: cursorOffset) {
                        textView.selectedTextRange = textView.textRange(from: pos, to: pos)
                    }
                    textViewDidChange(textView)
                    return false
                }

                // Return — handle list continuation on the completed text
                if let action = newlineAction(for: completedText, at: completedCaret) {
                    applyNewlineAction(action, in: textView, text: completedText, insertionLocation: completedCaret)
                } else {
                    let inserted = (completedText as NSString).replacingCharacters(
                        in: NSRange(location: completedCaret, length: 0), with: "\n"
                    )
                    textView.text = inserted
                    parent.text = inserted
                    let cursorOffset = completedCaret + 1
                    if let pos = textView.position(from: textView.beginningOfDocument, offset: cursorOffset) {
                        textView.selectedTextRange = textView.textRange(from: pos, to: pos)
                    }
                    textViewDidChange(textView)
                }
                return false
            }

            // List continuation on return
            guard replacement == "\n", range.length == 0, textView.markedTextRange == nil else {
                return true
            }

            if let action = newlineAction(for: currentText, at: range.location) {
                applyNewlineAction(action, in: textView, text: currentText, insertionLocation: range.location)
                return false
            }

            return true
        }

        // MARK: - List continuation helpers

        private enum NewlineAction {
            case insert(String)
            case exitList(lineRange: NSRange, replacementLine: String)
        }

        private func newlineAction(for text: String, at location: Int) -> NewlineAction? {
            let nsText = text as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))

            // Only continue lists when Enter is pressed at end-of-line
            let trailingLength = max(0, lineRange.location + lineRange.length - location)
            if trailingLength > 0 {
                let trailing = nsText.substring(with: NSRange(location: location, length: trailingLength))
                    .trimmingCharacters(in: .newlines)
                if !trailing.isEmpty { return nil }
            }

            let rawLine = nsText.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")

            if let replacementLine = NoteTextViewListEditing.exitListReplacement(for: rawLine) {
                return .exitList(lineRange: lineRange, replacementLine: replacementLine)
            }
            if let continuation = NoteTextViewListEditing.continuationPrefix(for: rawLine) {
                return .insert("\n\(continuation)")
            }
            return nil
        }

        private func applyNewlineAction(_ action: NewlineAction, in textView: UITextView, text: String, insertionLocation: Int) {
            switch action {
            case .insert(let insertion):
                let nsText = text as NSString
                let newText = nsText.replacingCharacters(in: NSRange(location: insertionLocation, length: 0), with: insertion)
                let cursor = insertionLocation + (insertion as NSString).length
                textView.text = newText
                parent.text = newText
                if let pos = textView.position(from: textView.beginningOfDocument, offset: cursor) {
                    textView.selectedTextRange = textView.textRange(from: pos, to: pos)
                }
                textViewDidChange(textView)

            case .exitList(let lineRange, let replacementLine):
                let nsText = text as NSString
                let contentRange = NoteTextViewListEditing.lineContentRange(for: lineRange, in: nsText)
                let newText = nsText.replacingCharacters(in: contentRange, with: replacementLine)
                let cursor = contentRange.location + (replacementLine as NSString).length
                textView.text = newText
                parent.text = newText
                if let pos = textView.position(from: textView.beginningOfDocument, offset: cursor) {
                    textView.selectedTextRange = textView.textRange(from: pos, to: pos)
                }
                textViewDidChange(textView)
            }
        }
    }
}

// MARK: - PasteAwareTextView

final class PasteAwareTextView: UITextView {
    var onImagePasted: ((UIImage) -> Void)?

    private static let imageUTIs = [
        "public.jpeg", "public.png", "public.heic", "public.heif",
        "public.image", "com.apple.uikit.image"
    ]

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pb = UIPasteboard.general
            if pb.hasImages { return true }
            if pb.contains(pasteboardTypes: Self.imageUTIs) { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        // Try high-level accessor first
        if let image = pb.image {
            onImagePasted?(image)
            return
        }
        // Try raw data for each known image UTI (covers HEIC, PNG, JPEG from any source)
        for type in Self.imageUTIs {
            if let data = pb.data(forPasteboardType: type), let image = UIImage(data: data) {
                onImagePasted?(image)
                return
            }
        }
        super.paste(sender)
    }
}
