import SwiftUI
import UIKit

/// A deliberately minimal note editor: plain text with two smart behaviors —
/// Markdown list auto-continuation and `#tag` autocomplete. The only styling is
/// `#tags` drawn in the accent color; no interactive ranges, no tappable
/// checkboxes. `- [ ]` is plain text that still continues on Return.
///
/// The list-continuation logic is shared with the rest of the app via
/// `NoteTextViewListEditing`; the tag-completion logic lives here.
struct PlainNoteEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var focusRequestID: UUID
    var extraBottomPadding: CGFloat = 0
    /// Space above the first line that the text can still scroll up into.
    var extraTopPadding: CGFloat = 0
    var tagSuggestions: [String] = []
    var onTagAccepted: (String) -> Void = { _ in }
    /// Handle for edits that come from outside the keyboard (toolbar, dictation).
    var controller: PlainNoteEditorController?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: extraTopPadding, left: 0, bottom: 0, right: 0)
        // A content inset, not a text-container one: UITextView keeps the caret clear of
        // content insets as you type, so the line being written stays above the bar
        // floating over the bottom of the editor.
        textView.contentInset.bottom = extraBottomPadding
        textView.verticalScrollIndicatorInsets = UIEdgeInsets(top: extraTopPadding, left: 0, bottom: extraBottomPadding, right: 0)
        textView.allowsEditingTextAttributes = false
        textView.text = text
        context.coordinator.configureCompletionLabel(in: textView)
        context.coordinator.applyTagStyling(textView)
        controller?.attach(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateTagSuggestions(tagSuggestions)
        controller?.attach(uiView, coordinator: context.coordinator)

        if uiView.contentInset.bottom != extraBottomPadding {
            uiView.contentInset.bottom = extraBottomPadding
            uiView.verticalScrollIndicatorInsets.bottom = extraBottomPadding
            context.coordinator.scrollCaretIntoView(uiView)
        }

        if uiView.text != text {
            uiView.text = text
            context.coordinator.applyTagStyling(uiView)
        }

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            if isFocused, !uiView.isFirstResponder {
                DispatchQueue.main.async {
                    guard context.coordinator.parent.isFocused else { return }
                    uiView.becomeFirstResponder()
                }
            }
        }

        if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }

        context.coordinator.refreshTagPreview(in: uiView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlainNoteEditor
        var lastFocusRequestID: UUID?

        private let completionLabel = UILabel()
        private var normalizedTagSuggestions: [String] = []

        init(_ parent: PlainNoteEditor) {
            self.parent = parent
        }

        // MARK: Setup

        func configureCompletionLabel(in textView: UITextView) {
            completionLabel.font = UIFont.preferredFont(forTextStyle: .body)
            completionLabel.textColor = .tertiaryLabel
            completionLabel.backgroundColor = .clear
            completionLabel.isUserInteractionEnabled = false
            completionLabel.isHidden = true
            textView.addSubview(completionLabel)
        }

        func updateTagSuggestions(_ tags: [String]) {
            var seen: Set<String> = []
            normalizedTagSuggestions = tags.compactMap { sanitizeTag($0) }.filter { tag in
                let key = tag.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
        }

        // MARK: Delegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            refreshTagPreview(in: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
            hideTagPreview()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            applyTagStyling(textView)
            refreshTagPreview(in: textView)
            scrollCaretIntoView(textView)
        }

        /// Keeps the caret above the bottom inset (the editor bar). UIKit's own
        /// scroll-to-caret misses edits it didn't type itself (list continuation,
        /// dictation) and can run before the text has been laid out.
        func scrollCaretIntoView(_ textView: UITextView) {
            DispatchQueue.main.async {
                guard textView.isFirstResponder, let end = textView.selectedTextRange?.end else { return }
                let caret = textView.caretRect(for: end)
                guard !caret.isNull, !caret.isInfinite else { return }
                let visibleBottom = textView.contentOffset.y + textView.bounds.height
                    - textView.adjustedContentInset.bottom
                guard caret.maxY > visibleBottom else { return }
                textView.contentOffset.y += caret.maxY - visibleBottom
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshTagPreview(in: textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            let currentText = textView.text ?? ""
            guard let swiftRange = Range(range, in: currentText) else { return true }

            // Accept an inline tag completion when the user types space or newline.
            if range.length == 0,
               textView.markedTextRange == nil,
               replacement == " " || replacement == "\n",
               let completion = currentTagCompletion(in: currentText, caretLocation: range.location) {
                let completedText = currentText.replacingCharacters(in: swiftRange, with: completion.suffix)
                let completedCaret = range.location + (completion.suffix as NSString).length
                parent.onTagAccepted(completion.tag)

                if replacement == " " {
                    applyManualInsertion(textView, text: completedText, insertionLocation: completedCaret, insertion: " ")
                } else {
                    let insertion = "\n" + (continuation(for: completedText, at: completedCaret) ?? "")
                    applyManualInsertion(textView, text: completedText, insertionLocation: completedCaret, insertion: insertion)
                }
                return false
            }

            // List auto-continuation on Return.
            if replacement == "\n", range.length == 0, textView.markedTextRange == nil {
                if let exit = exitReplacement(for: currentText, at: range.location) {
                    applyLineReplacement(textView, text: currentText, lineRange: exit.lineRange, replacementLine: exit.replacementLine)
                    return false
                }
                if let prefix = continuation(for: currentText, at: range.location) {
                    applyManualInsertion(textView, text: currentText, insertionLocation: range.location, insertion: "\n" + prefix)
                    return false
                }
            }

            return true
        }

        // MARK: List continuation

        /// Continuation prefix to insert after Return, or nil when the line isn't a
        /// list item or the caret isn't at end-of-line.
        private func continuation(for text: String, at location: Int) -> String? {
            guard isAtLineEnd(text, location: location) else { return nil }
            let line = currentLine(text, location: location)
            return NoteTextViewListEditing.continuationPrefix(for: line)
        }

        /// When Return is pressed on an empty list item, clear the marker instead of continuing.
        private func exitReplacement(for text: String, at location: Int) -> (lineRange: NSRange, replacementLine: String)? {
            guard isAtLineEnd(text, location: location) else { return nil }
            let nsText = text as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let line = nsText.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
            guard let replacement = NoteTextViewListEditing.exitListReplacement(for: line) else { return nil }
            return (lineRange, replacement)
        }

        private func isAtLineEnd(_ text: String, location: Int) -> Bool {
            let nsText = text as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let trailingLength = max(0, lineRange.location + lineRange.length - location)
            guard trailingLength > 0 else { return true }
            let trailing = nsText.substring(with: NSRange(location: location, length: trailingLength))
                .trimmingCharacters(in: .newlines)
            return trailing.isEmpty
        }

        private func currentLine(_ text: String, location: Int) -> String {
            let nsText = text as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            return nsText.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
        }

        // MARK: Manual mutation (plain text, no styling)

        private func applyManualInsertion(_ textView: UITextView, text: String, insertionLocation: Int, insertion: String) {
            let nsText = text as NSString
            let inserted = nsText.replacingCharacters(in: NSRange(location: insertionLocation, length: 0), with: insertion)
            let caret = insertionLocation + (insertion as NSString).length
            applyReplacement(textView, newText: inserted, caretOffset: caret)
        }

        private func applyLineReplacement(_ textView: UITextView, text: String, lineRange: NSRange, replacementLine: String) {
            let nsText = text as NSString
            let contentRange = NoteTextViewListEditing.lineContentRange(for: lineRange, in: nsText)
            let replaced = nsText.replacingCharacters(in: contentRange, with: replacementLine)
            let caret = contentRange.location + (replacementLine as NSString).length
            applyReplacement(textView, newText: replaced, caretOffset: caret)
        }

        func applyReplacement(_ textView: UITextView, newText: String, caretOffset: Int) {
            textView.text = newText
            applyTagStyling(textView)
            parent.text = newText
            if let cursor = textView.position(from: textView.beginningOfDocument, offset: caretOffset) {
                textView.selectedTextRange = textView.textRange(from: cursor, to: cursor)
            }
            refreshTagPreview(in: textView)
            scrollCaretIntoView(textView)
        }

        // MARK: Tag styling

        private static let tagRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])#[A-Za-z0-9_-]+"#)
        private static let tagColor = UIColor(appAccent)

        /// Colors every `#tag`. Attributes only — the characters and selection are
        /// untouched. Skipped mid-composition so marked (IME) text isn't disturbed.
        func applyTagStyling(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let storage = textView.textStorage
            let fullRange = NSRange(location: 0, length: storage.length)
            let base: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]
            storage.beginEditing()
            storage.setAttributes(base, range: fullRange)
            for match in Self.tagRegex.matches(in: storage.string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: Self.tagColor, range: match.range)
            }
            storage.endEditing()
            // Typing right after a tag must not inherit its color.
            textView.typingAttributes = base
        }

        // MARK: Tag completion

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
                guard let scalar = previous.unicodeScalars.first, isTagCharacter(scalar) else {
                    return nil
                }
                scan -= 1
            }

            guard let hashLocation else { return nil }

            if hashLocation > 0 {
                let leading = nsText.substring(with: NSRange(location: hashLocation - 1, length: 1))
                if let scalar = leading.unicodeScalars.first, isTagCharacter(scalar) {
                    return nil
                }
            }

            if caretLocation < nsText.length {
                let trailing = nsText.substring(with: NSRange(location: caretLocation, length: 1))
                if let scalar = trailing.unicodeScalars.first, isTagCharacter(scalar) {
                    return nil
                }
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

        func refreshTagPreview(in textView: UITextView) {
            guard textView.selectedRange.length == 0 else {
                hideTagPreview()
                return
            }

            let currentText = textView.text ?? ""
            let caretLocation = textView.selectedRange.location
            guard let completion = currentTagCompletion(in: currentText, caretLocation: caretLocation),
                  !completion.suffix.isEmpty,
                  let caretPosition = textView.position(from: textView.beginningOfDocument, offset: completion.caretLocation) else {
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

        // MARK: Helpers

        private func sanitizeTag(_ raw: String) -> String? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("#") {
                value.removeFirst()
            }
            guard !value.isEmpty else { return nil }
            guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                return nil
            }
            return value
        }

        private func isTagCharacter(_ scalar: UnicodeScalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar)
                || scalar.value == 95  // _
                || scalar.value == 45  // -
        }
    }
}

/// Lets the editor's surroundings edit the text the way the keyboard would — at the
/// caret, through the same delegate path, so the binding and tag styling follow.
@MainActor
final class PlainNoteEditorController {
    private weak var textView: UITextView?
    private weak var coordinator: PlainNoteEditor.Coordinator?

    /// The span the in-progress dictation occupies; rewritten on every partial result.
    private var dictationRange: NSRange?
    private var dictationPrefix = ""

    fileprivate func attach(_ textView: UITextView, coordinator: PlainNoteEditor.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
    }

    /// Inserts `#` at the caret, spaced off from a preceding word so it starts a tag.
    func insertTagMarker() {
        guard let textView else { return }
        textView.insertText(needsLeadingSpace(in: textView) ? " #" : "#")
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
    }

    func beginDictation() {
        guard let textView else { return }
        let caret = textView.selectedRange
        dictationRange = NSRange(location: caret.location, length: caret.length)
        dictationPrefix = needsLeadingSpace(in: textView) ? " " : ""
    }

    /// Replaces what dictation has written so far with the latest transcript.
    func updateDictation(_ transcript: String) {
        guard let textView, let coordinator, let range = dictationRange, !transcript.isEmpty else { return }
        let current = (textView.text ?? "") as NSString
        guard NSMaxRange(range) <= current.length else {
            // The text moved under us (edited mid-dictation) — stop rewriting.
            dictationRange = nil
            return
        }
        let insertion = dictationPrefix + transcript
        let length = (insertion as NSString).length
        let newText = current.replacingCharacters(in: range, with: insertion)
        coordinator.applyReplacement(textView, newText: newText, caretOffset: range.location + length)
        dictationRange = NSRange(location: range.location, length: length)
    }

    func endDictation() {
        dictationRange = nil
        dictationPrefix = ""
    }

    private func needsLeadingSpace(in textView: UITextView) -> Bool {
        let location = textView.selectedRange.location
        guard location > 0, let text = textView.text else { return false }
        let previous = (text as NSString).substring(with: NSRange(location: location - 1, length: 1))
        return !(previous.first?.isWhitespace ?? true)
    }
}
