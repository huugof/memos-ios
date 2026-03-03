import SwiftUI
import UIKit

struct NoteTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var focusRequestID: UUID
    var tagSuggestions: [String] = []
    var onTagAccepted: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.text = text
        context.coordinator.configureCompletionLabel(in: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateTagSuggestions(tagSuggestions)

        if uiView.text != text {
            uiView.text = text
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
        var parent: NoteTextView
        var lastFocusRequestID: UUID?

        private let completionLabel = UILabel()
        private var normalizedTagSuggestions: [String] = []

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func configureCompletionLabel(in textView: UITextView) {
            completionLabel.font = UIFont.preferredFont(forTextStyle: .body)
            completionLabel.textColor = UIColor.tertiaryLabel
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
            refreshTagPreview(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshTagPreview(in: textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            let currentText = textView.text ?? ""
            guard let swiftRange = Range(range, in: currentText) else {
                return true
            }

            if range.length == 0,
               textView.markedTextRange == nil,
               (replacement == " " || replacement == "\n"),
               let completion = currentTagCompletion(in: currentText, caretLocation: range.location) {
                let completedText = currentText.replacingCharacters(in: swiftRange, with: completion.suffix)
                let completedCaretLocation = range.location + (completion.suffix as NSString).length
                parent.onTagAccepted(completion.tag)

                if replacement == " " {
                    applyManualInsertion(
                        textView,
                        text: completedText,
                        insertionLocation: completedCaretLocation,
                        insertion: " "
                    )
                    return false
                }

                let insertion = newlineInsertion(for: completedText, at: completedCaretLocation) ?? "\n"
                applyManualInsertion(
                    textView,
                    text: completedText,
                    insertionLocation: completedCaretLocation,
                    insertion: insertion
                )
                return false
            }

            guard replacement == "\n", range.length == 0, textView.markedTextRange == nil else {
                return true
            }

            guard let insertion = newlineInsertion(for: currentText, at: range.location) else {
                return true
            }

            let newText = currentText.replacingCharacters(in: swiftRange, with: insertion)
            let cursorOffset = range.location + (insertion as NSString).length
            applyManualReplacement(textView, newText: newText, cursorOffset: cursorOffset)
            return false
        }

        func refreshTagPreview(in textView: UITextView) {
            guard textView.selectedRange.length == 0 else {
                hideTagPreview()
                return
            }

            let currentText = textView.text ?? ""
            let caretLocation = textView.selectedRange.location
            guard let completion = currentTagCompletion(in: currentText, caretLocation: caretLocation),
                  !completion.suffix.isEmpty else {
                hideTagPreview()
                return
            }

            guard let caretPosition = textView.position(from: textView.beginningOfDocument, offset: completion.caretLocation) else {
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

        private func hideTagPreview() {
            completionLabel.isHidden = true
        }

        private func applyManualInsertion(
            _ textView: UITextView,
            text: String,
            insertionLocation: Int,
            insertion: String
        ) {
            let nsText = text as NSString
            let inserted = nsText.replacingCharacters(in: NSRange(location: insertionLocation, length: 0), with: insertion)
            let cursorOffset = insertionLocation + (insertion as NSString).length
            applyManualReplacement(textView, newText: inserted, cursorOffset: cursorOffset)
        }

        private func applyManualReplacement(_ textView: UITextView, newText: String, cursorOffset: Int) {
            textView.text = newText
            parent.text = newText

            if let cursor = textView.position(from: textView.beginningOfDocument, offset: cursorOffset) {
                textView.selectedTextRange = textView.textRange(from: cursor, to: cursor)
            }

            refreshTagPreview(in: textView)
        }

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

        private func newlineInsertion(for text: String, at location: Int) -> String? {
            let nsText = text as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))

            // Continue lists only when Enter is pressed at end-of-line.
            let trailingLength = max(0, lineRange.location + lineRange.length - location)
            if trailingLength > 0 {
                let trailing = nsText.substring(with: NSRange(location: location, length: trailingLength))
                    .trimmingCharacters(in: .newlines)
                if !trailing.isEmpty {
                    return nil
                }
            }

            let rawLine = nsText.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
            guard let continuation = continuationPrefix(for: rawLine) else {
                return nil
            }

            return "\n\(continuation)"
        }

        private func continuationPrefix(for line: String) -> String? {
            if let continuation = taskContinuation(for: line) {
                return continuation
            }

            if let continuation = unorderedContinuation(for: line) {
                return continuation
            }

            if let continuation = orderedContinuation(for: line) {
                return continuation
            }

            return nil
        }

        private func taskContinuation(for line: String) -> String? {
            guard let match = firstMatch(in: line, pattern: #"^(\s*)([-*+])\s+\[(?: |x|X)\]\s+(.*)$"#) else {
                return nil
            }

            let indent = match[1]
            let marker = match[2]
            let content = match[3].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }

            return "\(indent)\(marker) [ ] "
        }

        private func unorderedContinuation(for line: String) -> String? {
            guard let match = firstMatch(in: line, pattern: #"^(\s*)([-*+])\s+(.*)$"#) else {
                return nil
            }

            let indent = match[1]
            let marker = match[2]
            let content = match[3].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }

            return "\(indent)\(marker) "
        }

        private func orderedContinuation(for line: String) -> String? {
            if let match = firstMatch(in: line, pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#) {
                let indent = match[1]
                let number = Int(match[2]) ?? 1
                let delimiter = match[3]
                let content = match[4].trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else { return nil }

                return "\(indent)\(number + 1)\(delimiter) "
            }

            if let match = firstMatch(in: line, pattern: #"^(\s*)(\d+)\s+(.*)$"#) {
                let indent = match[1]
                let number = Int(match[2]) ?? 1
                let content = match[3].trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else { return nil }

                return "\(indent)\(number + 1) "
            }

            return nil
        }

        private func firstMatch(in text: String, pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

            var values: [String] = []
            for idx in 0..<match.numberOfRanges {
                let matchRange = match.range(at: idx)
                guard let swiftRange = Range(matchRange, in: text) else {
                    values.append("")
                    continue
                }
                values.append(String(text[swiftRange]))
            }
            return values
        }

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
                || scalar.value == 95
                || scalar.value == 45
        }
    }
}
