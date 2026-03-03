import SwiftUI
import UIKit

struct NoteTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var focusRequestID: UUID

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
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self

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
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteTextView
        var lastFocusRequestID: UUID?

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard replacement == "\n", range.length == 0, textView.markedTextRange == nil else {
                return true
            }

            let currentText = textView.text ?? ""
            let nsText = currentText as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))

            // Continue lists only when Enter is pressed at end-of-line.
            let trailingLength = max(0, lineRange.location + lineRange.length - range.location)
            if trailingLength > 0 {
                let trailing = nsText.substring(with: NSRange(location: range.location, length: trailingLength))
                    .trimmingCharacters(in: .newlines)
                if !trailing.isEmpty {
                    return true
                }
            }

            let rawLine = nsText.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
            guard let continuation = continuationPrefix(for: rawLine) else {
                return true
            }

            guard let swiftRange = Range(range, in: currentText) else {
                return true
            }

            let insertion = "\n\(continuation)"
            let newText = currentText.replacingCharacters(in: swiftRange, with: insertion)
            textView.text = newText
            parent.text = newText

            let cursorOffset = range.location + (insertion as NSString).length
            if let cursor = textView.position(from: textView.beginningOfDocument, offset: cursorOffset) {
                textView.selectedTextRange = textView.textRange(from: cursor, to: cursor)
            }

            return false
        }

        private func continuationPrefix(for line: String) -> String? {
            if let continuation = unorderedContinuation(for: line) {
                return continuation
            }

            if let continuation = orderedContinuation(for: line) {
                return continuation
            }

            return nil
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
    }
}
