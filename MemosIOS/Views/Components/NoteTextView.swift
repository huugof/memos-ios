import SwiftUI
import UIKit

struct EditableNoteTextView: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var focusRequestID: UUID
    var extraBottomScrollPadding: CGFloat = 120
    var tagSuggestions: [String] = []
    var onTagAccepted: (String) -> Void = { _ in }
    var onTagTapped: (String) -> Void = { _ in }

    var body: some View {
        NoteTextView(
            text: $text,
            isFocused: $isFocused,
            focusRequestID: focusRequestID,
            isEditingEnabled: true,
            allowsScrolling: true,
            extraBottomScrollPadding: extraBottomScrollPadding,
            tagSuggestions: tagSuggestions,
            onTagAccepted: onTagAccepted,
            onTagTapped: onTagTapped
        )
    }
}

struct RenderedNoteTextView: View {
    @Binding var text: String
    var allowsScrolling: Bool = false
    var onTagTapped: (String) -> Void = { _ in }
    var onNonInteractiveTap: (() -> Void)? = nil

    var body: some View {
        NoteTextView(
            text: $text,
            isFocused: .constant(false),
            focusRequestID: UUID(),
            isEditingEnabled: false,
            allowsScrolling: allowsScrolling,
            onTagTapped: onTagTapped,
            onNonInteractiveTap: onNonInteractiveTap
        )
    }
}

struct NoteTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var focusRequestID: UUID
    var isEditingEnabled: Bool = true
    var allowsScrolling: Bool = true
    var extraBottomScrollPadding: CGFloat = 0
    var tagSuggestions: [String] = []
    var onTagAccepted: (String) -> Void = { _ in }
    var onTagTapped: (String) -> Void = { _ in }
    var onNonInteractiveTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = OverlayAwareTextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = allowsScrolling
        textView.keyboardDismissMode = isEditingEnabled ? .interactive : .none
        textView.textContainer.lineFragmentPadding = 0
        textView.isSelectable = isEditingEnabled
        textView.isEditable = isEditingEnabled
        textView.isScrollEnabled = allowsScrolling
        textView.allowsEditingTextAttributes = false
        textView.text = text
        context.coordinator.applyTextInsets(to: textView)

        if isEditingEnabled {
            context.coordinator.configureCompletionLabel(in: textView)
        }
        context.coordinator.configureMarkdownInteractions(in: textView)
        context.coordinator.applyMarkdownStyling(in: textView, forceFullPass: true)

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateTagSuggestions(tagSuggestions)
        context.coordinator.updateInteractionMode(isEditingEnabled: isEditingEnabled)
        uiView.isEditable = isEditingEnabled
        uiView.isSelectable = isEditingEnabled
        uiView.isScrollEnabled = allowsScrolling
        uiView.alwaysBounceVertical = allowsScrolling
        uiView.keyboardDismissMode = isEditingEnabled ? .interactive : .none
        context.coordinator.applyTextInsets(to: uiView)

        let didReplaceText = uiView.text != text
        if didReplaceText {
            uiView.text = text
            context.coordinator.clearPendingEditContext()
        }

        if isEditingEnabled, context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            if isFocused, !uiView.isFirstResponder {
                DispatchQueue.main.async {
                    guard context.coordinator.parent.isFocused else { return }
                    uiView.becomeFirstResponder()
                }
            }
        }

        if (!isFocused || !isEditingEnabled), uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }

        if didReplaceText || context.coordinator.needsRestyle(for: uiView.text ?? "") {
            context.coordinator.applyMarkdownStyling(in: uiView, forceFullPass: true)
        }

        if isEditingEnabled {
            context.coordinator.refreshTagPreview(in: uiView)
        } else {
            context.coordinator.hideTagPreview()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard !allowsScrolling else { return nil }
        let targetWidth = proposal.width ?? uiView.bounds.width
        guard targetWidth > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: targetWidth, height: max(22, fitting.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: NoteTextView
        var lastFocusRequestID: UUID?

        private enum NewlineAction {
            case insert(String)
            case exitList(lineRange: NSRange, replacementLine: String)
        }

        private let completionLabel = UILabel()
        private var normalizedTagSuggestions: [String] = []

        private var interactiveRanges: [MarkdownLiteFormatter.InteractiveRange] = []
        private var pendingEditContext: MarkdownLiteFormatter.EditContext?
        private(set) var lastStyledText: String = ""

        private weak var markdownTextView: UITextView?
        private lazy var markdownTapRecognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleMarkdownTap(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = true
            return recognizer
        }()

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

        func configureMarkdownInteractions(in textView: UITextView) {
            markdownTextView = textView
            let hasRecognizer = textView.gestureRecognizers?.contains(where: { $0 === markdownTapRecognizer }) ?? false
            if !hasRecognizer {
                textView.addGestureRecognizer(markdownTapRecognizer)
            }
            updateInteractionMode(isEditingEnabled: parent.isEditingEnabled)
        }

        func updateInteractionMode(isEditingEnabled: Bool) {
            markdownTapRecognizer.isEnabled = !isEditingEnabled
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

        func clearPendingEditContext() {
            pendingEditContext = nil
        }

        func applyTextInsets(to textView: UITextView) {
            let bottomInset = parent.isEditingEnabled && parent.allowsScrolling
                ? parent.extraBottomScrollPadding
                : 0
            textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
            textView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }

        func needsRestyle(for text: String) -> Bool {
            lastStyledText != text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard parent.isEditingEnabled else { return }
            parent.isFocused = true
            refreshTagPreview(in: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard parent.isEditingEnabled else { return }
            parent.isFocused = false
            hideTagPreview()
        }

        func textViewDidChange(_ textView: UITextView) {
            let newText = textView.text ?? ""
            parent.text = newText
            applyMarkdownStyling(in: textView, forceFullPass: false)
            refreshTagPreview(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshTagPreview(in: textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard parent.isEditingEnabled else { return false }
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
                        insertion: " ",
                        oldText: currentText
                    )
                    return false
                }

                let action = newlineAction(for: completedText, at: completedCaretLocation) ?? .insert("\n")
                applyNewlineAction(
                    action,
                    in: textView,
                    text: completedText,
                    oldText: currentText,
                    insertionLocation: completedCaretLocation
                )
                return false
            }

            guard replacement == "\n", range.length == 0, textView.markedTextRange == nil else {
                pendingEditContext = MarkdownLiteFormatter.EditContext(oldText: currentText, range: range, replacement: replacement)
                return true
            }

            guard let action = newlineAction(for: currentText, at: range.location) else {
                pendingEditContext = MarkdownLiteFormatter.EditContext(oldText: currentText, range: range, replacement: replacement)
                return true
            }

            applyNewlineAction(action, in: textView, text: currentText, oldText: currentText, insertionLocation: range.location)
            return false
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard parent.isEditingEnabled else { return nil }

            if textItem.value(forKey: "link") as? URL != nil {
                return defaultAction
            }

            guard let identifier = textItem.value(forKey: "tagIdentifier") as? String,
                  let tag = MarkdownLiteFormatter.parseTextItemTag(identifier) else {
                return nil
            }

            switch tag {
            case .checkbox:
                return UIAction { [weak self, weak textView] _ in
                    guard let self, let textView else { return }
                    self.toggleCheckbox(in: textView, at: textItem.range.location)
                }
            case .tag(let value):
                return UIAction { [weak self] _ in
                    self?.parent.onTagTapped(value)
                }
            }
        }

        func textView(
            _ textView: UITextView,
            menuConfigurationFor textItem: UITextItem,
            defaultMenu: UIMenu
        ) -> UITextItem.MenuConfiguration? {
            guard parent.isEditingEnabled else { return nil }
            return nil
        }

        func refreshTagPreview(in textView: UITextView) {
            guard parent.isEditingEnabled else {
                hideTagPreview()
                return
            }
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

        func hideTagPreview() {
            completionLabel.isHidden = true
        }

        func applyMarkdownStyling(in textView: UITextView, forceFullPass: Bool) {
            guard textView.markedTextRange == nil else {
                return
            }

            let text = textView.text ?? ""
            let nsText = text as NSString
            let theme = MarkdownLiteFormatter.Theme.default(for: textView)
            let baseAttributes = MarkdownLiteFormatter.baseAttributes(theme: theme)
            let fullRange = NSRange(location: 0, length: nsText.length)

            let selectedRange = textView.selectedRange
            let shouldUsePlainMode = MarkdownLiteFormatter.shouldUsePlainMode(for: text)

            if shouldUsePlainMode {
                textView.textStorage.beginEditing()
                textView.textStorage.setAttributes(baseAttributes, range: fullRange)
                textView.textStorage.endEditing()
                textView.typingAttributes = baseAttributes
                interactiveRanges = []
                updateCheckboxRendering(in: textView)
                lastStyledText = text
                pendingEditContext = nil
                restoreSelection(selectedRange, in: textView)
                return
            }

            let shouldFullPass = forceFullPass || MarkdownLiteFormatter.shouldUseFullPass(edit: pendingEditContext)
            let targetRange = shouldFullPass
                ? fullRange
                : MarkdownLiteFormatter.expandedLineRange(in: nsText, around: pendingEditContext)

            let renderResult = shouldFullPass
                ? MarkdownLiteFormatter.fullRender(text: text, theme: theme)
                : MarkdownLiteFormatter.partialRender(text: text, range: targetRange, theme: theme)

            textView.textStorage.beginEditing()
            textView.textStorage.setAttributes(baseAttributes, range: targetRange)
            for run in renderResult.runs {
                textView.textStorage.addAttributes(run.attributes, range: run.range)
            }
            textView.textStorage.endEditing()
            textView.typingAttributes = baseAttributes

            if shouldFullPass {
                interactiveRanges = renderResult.interactiveRanges
            } else {
                interactiveRanges = mergeInteractiveRanges(
                    existing: interactiveRanges,
                    replacing: targetRange,
                    with: renderResult.interactiveRanges
                )
            }

            lastStyledText = text
            pendingEditContext = nil
            restoreSelection(selectedRange, in: textView)
            updateCheckboxRendering(in: textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            (textView as? OverlayAwareTextView)?.setNeedsDisplay()
        }

        private func restoreSelection(_ selection: NSRange, in textView: UITextView) {
            let length = (textView.text as NSString?)?.length ?? 0
            let clampedLocation = min(max(0, selection.location), length)
            let clampedLength = min(max(0, selection.length), max(0, length - clampedLocation))
            textView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
        }

        private func mergeInteractiveRanges(
            existing: [MarkdownLiteFormatter.InteractiveRange],
            replacing range: NSRange,
            with fresh: [MarkdownLiteFormatter.InteractiveRange]
        ) -> [MarkdownLiteFormatter.InteractiveRange] {
            var merged = existing.filter { NSIntersectionRange($0.range, range).length == 0 }
            merged.append(contentsOf: fresh)
            merged.sort { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                return lhs.range.length < rhs.range.length
            }
            return merged
        }

        private func applyManualInsertion(
            _ textView: UITextView,
            text: String,
            insertionLocation: Int,
            insertion: String,
            oldText: String
        ) {
            let nsText = text as NSString
            let inserted = nsText.replacingCharacters(in: NSRange(location: insertionLocation, length: 0), with: insertion)
            let cursorOffset = insertionLocation + (insertion as NSString).length
            applyManualReplacement(
                textView,
                newText: inserted,
                cursorOffset: cursorOffset,
                oldText: oldText,
                changedRange: NSRange(location: insertionLocation, length: 0),
                replacement: insertion
            )
        }

        private func applyManualReplacement(
            _ textView: UITextView,
            newText: String,
            cursorOffset: Int?,
            oldText: String,
            changedRange: NSRange,
            replacement: String,
            preserveViewport: Bool = false
        ) {
            let previousSelection = textView.selectedRange
            let previousOffset = textView.contentOffset
            textView.text = newText
            parent.text = newText
            pendingEditContext = MarkdownLiteFormatter.EditContext(oldText: oldText, range: changedRange, replacement: replacement)

            if parent.isEditingEnabled {
                if let cursorOffset,
                   let cursor = textView.position(from: textView.beginningOfDocument, offset: cursorOffset) {
                    textView.selectedTextRange = textView.textRange(from: cursor, to: cursor)
                } else {
                    restoreSelection(previousSelection, in: textView)
                }
            }

            applyMarkdownStyling(in: textView, forceFullPass: false)
            if preserveViewport, textView.isScrollEnabled {
                textView.setContentOffset(previousOffset, animated: false)
            }
            refreshTagPreview(in: textView)
        }

        private func toggleCheckbox(in textView: UITextView, at location: Int) {
            guard let toggled = MarkdownLiteFormatter.toggleCheckbox(
                in: textView.text ?? "",
                at: location,
                interactiveRanges: interactiveRanges
            ) else {
                return
            }

            let oldText = textView.text ?? ""
            applyManualReplacement(
                textView,
                newText: toggled,
                cursorOffset: nil,
                oldText: oldText,
                changedRange: NSRange(location: location, length: 0),
                replacement: "",
                preserveViewport: true
            )
        }

        private func updateCheckboxRendering(in textView: UITextView) {
            guard let overlayTextView = textView as? OverlayAwareTextView else { return }
            overlayTextView.checkboxRenderRanges = interactiveRanges.compactMap { range -> OverlayAwareTextView.CheckboxRenderRange? in
                guard case let .checkbox(isChecked) = range.kind else { return nil }
                return OverlayAwareTextView.CheckboxRenderRange(range: range.range, isChecked: isChecked)
            }
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

        private func applyNewlineAction(
            _ action: NewlineAction,
            in textView: UITextView,
            text: String,
            oldText: String,
            insertionLocation: Int
        ) {
            switch action {
            case .insert(let insertion):
                applyManualInsertion(
                    textView,
                    text: text,
                    insertionLocation: insertionLocation,
                    insertion: insertion,
                    oldText: oldText
                )
            case .exitList(let lineRange, let replacementLine):
                applyLineReplacement(
                    textView,
                    text: text,
                    lineRange: lineRange,
                    replacementLine: replacementLine,
                    oldText: oldText
                )
            }
        }

        private func newlineAction(for text: String, at location: Int) -> NewlineAction? {
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
            if let replacementLine = exitListReplacement(for: rawLine) {
                return .exitList(lineRange: lineRange, replacementLine: replacementLine)
            }

            guard let continuation = continuationPrefix(for: rawLine) else {
                return nil
            }

            return .insert("\n\(continuation)")
        }

        private func applyLineReplacement(
            _ textView: UITextView,
            text: String,
            lineRange: NSRange,
            replacementLine: String,
            oldText: String
        ) {
            let nsText = text as NSString
            let contentRange = lineContentRange(for: lineRange, in: nsText)
            let replaced = nsText.replacingCharacters(in: contentRange, with: replacementLine)
            let cursorOffset = contentRange.location + (replacementLine as NSString).length

            applyManualReplacement(
                textView,
                newText: replaced,
                cursorOffset: cursorOffset,
                oldText: oldText,
                changedRange: contentRange,
                replacement: replacementLine
            )
        }

        private func lineContentRange(for lineRange: NSRange, in text: NSString) -> NSRange {
            guard lineRange.length > 0 else { return lineRange }
            let lastCharacterIndex = lineRange.location + lineRange.length - 1
            guard lastCharacterIndex >= 0, lastCharacterIndex < text.length else {
                return lineRange
            }

            let lastCharacter = text.substring(with: NSRange(location: lastCharacterIndex, length: 1))
            if lastCharacter == "\n" {
                return NSRange(location: lineRange.location, length: max(0, lineRange.length - 1))
            }
            return lineRange
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

        private func exitListReplacement(for line: String) -> String? {
            if let match = firstMatch(in: line, pattern: #"^(\s*)([-*+])\s+\[(?: |x|X)\]\s*$"#) {
                return match[1]
            }

            if let match = firstMatch(in: line, pattern: #"^(\s*)([-*+])\s*$"#) {
                return match[1]
            }

            if let match = firstMatch(in: line, pattern: #"^(\s*)(\d+)([.)])\s*$"#) {
                return match[1]
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

        @objc
        private func handleMarkdownTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = markdownTextView else {
                return
            }

            let tapPoint = recognizer.location(in: textView)
            guard let characterIndex = characterIndex(at: tapPoint, in: textView) else {
                return
            }

            if interactiveRanges.contains(where: {
                guard case .checkbox = $0.kind else { return false }
                return NSLocationInRange(characterIndex, $0.range)
            }) {
                toggleCheckbox(in: textView, at: characterIndex)
                return
            }

            if let url = MarkdownLiteFormatter.url(at: characterIndex, interactiveRanges: interactiveRanges) {
                UIApplication.shared.open(url)
                return
            }

            if let tag = MarkdownLiteFormatter.tag(at: characterIndex, interactiveRanges: interactiveRanges) {
                parent.onTagTapped(tag)
                return
            }

            parent.onNonInteractiveTap?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === markdownTapRecognizer,
                  let textView = markdownTextView else {
                return false
            }
            let point = touch.location(in: textView)
            guard let index = characterIndex(at: point, in: textView) else { return false }
            if interactiveRanges.contains(where: { NSLocationInRange(index, $0.range) }) {
                return true
            }

            return parent.onNonInteractiveTap != nil
        }

        private func characterIndex(at point: CGPoint, in textView: UITextView) -> Int? {
            let textBounds = textView.bounds.insetBy(dx: -12, dy: -12)
            guard textBounds.contains(point) else {
                return nil
            }

            let adjustedPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            var fraction: CGFloat = 0
            let rawIndex = layoutManager.characterIndex(
                for: adjustedPoint,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )

            let length = (textView.text as NSString?)?.length ?? 0
            guard length > 0 else { return nil }
            return min(max(0, rawIndex), max(0, length - 1))
        }
    }
}

private final class OverlayAwareTextView: UITextView {
    struct CheckboxRenderRange: Equatable {
        let range: NSRange
        let isChecked: Bool
    }

    var checkboxRenderRanges: [CheckboxRenderRange] = [] {
        didSet {
            guard checkboxRenderRanges != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawCheckboxes(in: rect)
    }

    private func drawCheckboxes(in rect: CGRect) {
        guard !checkboxRenderRanges.isEmpty else { return }

        for checkbox in checkboxRenderRanges {
            guard let checkboxRect = checkboxRect(for: checkbox.range), checkboxRect.intersects(rect) else {
                continue
            }

            let basePointSize = (font ?? UIFont.preferredFont(forTextStyle: .body)).pointSize
            let visualSize = max(basePointSize + 7, 24)
            let imageName = checkbox.isChecked ? "checkmark.square" : "square"
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: visualSize, weight: .regular)
            guard let image = UIImage(systemName: imageName, withConfiguration: symbolConfig) else {
                continue
            }
            let tintedImage = image.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)

            let imageRect = CGRect(
                x: checkboxRect.minX,
                y: checkboxRect.midY - (visualSize / 2),
                width: visualSize,
                height: visualSize
            ).integral

            tintedImage.draw(in: imageRect)
        }
    }

    private func checkboxRect(for range: NSRange) -> CGRect? {
        let textLength = (text as NSString).length
        guard textLength > 0 else { return nil }
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: textLength))
        guard safeRange.length > 0 else { return nil }

        let layoutManager = self.layoutManager
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.left - contentOffset.x
        rect.origin.y += textContainerInset.top - contentOffset.y

        if rect.height < 1 {
            rect.size.height = font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        }

        if rect.width < 1 {
            rect.size.width = rect.height
        }

        guard rect.isNull == false, rect.isInfinite == false, rect.width > 0, rect.height > 0 else {
            return nil
        }

        return rect
    }
}
