import Foundation
import UIKit

struct MarkdownLiteFormatter {
    struct Theme {
        let baseFont: UIFont
        let headerFont: UIFont
        let textColor: UIColor
        let secondaryTextColor: UIColor
        let linkColor: UIColor

        static func `default`(for textView: UITextView) -> Theme {
            let base = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let header = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
            return Theme(
                baseFont: base,
                headerFont: header,
                textColor: .label,
                secondaryTextColor: .secondaryLabel,
                linkColor: textView.tintColor
            )
        }
    }

    struct AttributeRun {
        let range: NSRange
        let attributes: [NSAttributedString.Key: Any]
    }

    enum InteractiveKind {
        case checkbox(isChecked: Bool)
        case link(URL)
    }

    struct InteractiveRange {
        let range: NSRange
        let kind: InteractiveKind
    }

    struct RenderResult {
        let runs: [AttributeRun]
        let interactiveRanges: [InteractiveRange]
    }

    struct EditContext {
        let oldText: String
        let range: NSRange
        let replacement: String
    }

    static let plainModeThreshold = 6_000

    static func baseAttributes(theme: Theme) -> [NSAttributedString.Key: Any] {
        [
            .font: theme.baseFont,
            .foregroundColor: theme.textColor
        ]
    }

    static func shouldUsePlainMode(for text: String) -> Bool {
        (text as NSString).length > plainModeThreshold
    }

    static func shouldUseFullPass(edit: EditContext?) -> Bool {
        guard let edit else { return true }
        if requiresFullPassForStructuralEdit(edit) {
            return true
        }

        let replacementLength = (edit.replacement as NSString).length
        if edit.replacement.contains("\n") {
            let newlineCount = edit.replacement.reduce(into: 0) { count, character in
                if character == "\n" {
                    count += 1
                }
            }
            let isSingleLineBreakInsertion = edit.range.length == 0 && newlineCount == 1 && replacementLength <= 8
            if !isSingleLineBreakInsertion {
                return true
            }
        }
        if max(edit.range.length, replacementLength) > 160 {
            return true
        }
        let delta = abs(replacementLength - edit.range.length)
        return delta > 200
    }

    static func expandedLineRange(in text: NSString, around edit: EditContext?) -> NSRange {
        guard let edit else {
            return NSRange(location: 0, length: text.length)
        }

        let clampedLocation = min(max(0, edit.range.location), text.length)
        let replacementLength = (edit.replacement as NSString).length
        let safeLength = min(replacementLength, max(0, text.length - clampedLocation))
        var lineRange = text.lineRange(for: NSRange(location: clampedLocation, length: safeLength))

        if lineRange.location > 0 {
            let previousLine = text.lineRange(for: NSRange(location: max(0, lineRange.location - 1), length: 0))
            lineRange = union(lineRange, previousLine)
        }

        let end = lineRange.location + lineRange.length
        if end < text.length {
            let nextLine = text.lineRange(for: NSRange(location: end, length: 0))
            lineRange = union(lineRange, nextLine)
        }

        return lineRange
    }

    static func fullRender(text: String, theme: Theme) -> RenderResult {
        let nsText = text as NSString
        return render(text: text, nsText: nsText, in: NSRange(location: 0, length: nsText.length), theme: theme)
    }

    static func partialRender(text: String, range: NSRange, theme: Theme) -> RenderResult {
        let nsText = text as NSString
        let safeRange = clamp(range, to: nsText.length)
        return render(text: text, nsText: nsText, in: safeRange, theme: theme)
    }

    static func toggleCheckbox(in text: String, at characterIndex: Int, interactiveRanges: [InteractiveRange]) -> String? {
        let nsText = text as NSString
        guard characterIndex >= 0, characterIndex <= nsText.length else {
            return nil
        }

        guard let hit = interactiveRanges.first(where: {
            switch $0.kind {
            case .checkbox:
                return NSLocationInRange(characterIndex, $0.range)
            case .link:
                return false
            }
        }) else {
            return nil
        }

        guard case let .checkbox(isChecked) = hit.kind else {
            return nil
        }

        let replacement = isChecked ? "[ ]" : "[x]"
        return nsText.replacingCharacters(in: hit.range, with: replacement)
    }

    static func url(at characterIndex: Int, interactiveRanges: [InteractiveRange]) -> URL? {
        guard let hit = interactiveRanges.first(where: {
            switch $0.kind {
            case .link:
                return NSLocationInRange(characterIndex, $0.range)
            case .checkbox:
                return false
            }
        }) else {
            return nil
        }

        if case let .link(url) = hit.kind {
            return url
        }
        return nil
    }

    private static func render(text: String, nsText: NSString, in targetRange: NSRange, theme: Theme) -> RenderResult {
        guard targetRange.length > 0 else {
            return RenderResult(runs: [], interactiveRanges: [])
        }

        var runs: [AttributeRun] = []
        var interactive: [InteractiveRange] = []

        enumerateLines(in: nsText, intersecting: targetRange) { lineRange in
            let line = nsText.substring(with: lineRange)
            parseLine(line, lineRange: lineRange, theme: theme, runs: &runs, interactive: &interactive)
        }

        parseInline(in: text, targetRange: targetRange, theme: theme, runs: &runs, interactive: &interactive)
        return RenderResult(runs: runs, interactiveRanges: interactive)
    }

    private static func parseLine(
        _ line: String,
        lineRange: NSRange,
        theme: Theme,
        runs: inout [AttributeRun],
        interactive: inout [InteractiveRange]
    ) {
        let nsLine = line as NSString

        if let match = firstMatch(in: line, regex: headerRegex) {
            runs.append(AttributeRun(range: lineRange, attributes: [.font: theme.headerFont]))
            let markerRange = match.range(at: 1)
            let markerPrefixLength = min(markerRange.length, nsLine.length)
            if markerPrefixLength > 0 {
                let prefixRange = NSRange(location: lineRange.location, length: markerPrefixLength)
                runs.append(AttributeRun(range: prefixRange, attributes: [.foregroundColor: theme.secondaryTextColor]))
            }
            return
        }

        if let match = firstMatch(in: line, regex: taskRegex) {
            let indent = nsLine.substring(with: match.range(at: 1))
            let marker = nsLine.substring(with: match.range(at: 2))
            let canonicalPrefix = "\(indent)\(marker) [ ] "
            applyListIndent(
                line: line,
                lineRange: lineRange,
                contentGroup: 4,
                match: match,
                theme: theme,
                runs: &runs,
                prefixOverride: canonicalPrefix
            )

            let checkedRange = match.range(at: 3)
            let isChecked = nsLine.substring(with: checkedRange).lowercased() == "x"
            let checkboxRange = NSRange(location: max(0, checkedRange.location - 1), length: 3)
            let absoluteCheckboxRange = NSRange(location: lineRange.location + checkboxRange.location, length: checkboxRange.length)

            interactive.append(InteractiveRange(range: absoluteCheckboxRange, kind: .checkbox(isChecked: isChecked)))
            runs.append(AttributeRun(range: absoluteCheckboxRange, attributes: [.foregroundColor: theme.secondaryTextColor]))

            if isChecked {
                let contentRange = match.range(at: 4)
                if contentRange.length > 0 {
                    let absoluteContentRange = NSRange(location: lineRange.location + contentRange.location, length: contentRange.length)
                    runs.append(AttributeRun(range: absoluteContentRange, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
                }
            }
            return
        }

        if let match = firstMatch(in: line, regex: unorderedListRegex) {
            applyListIndent(line: line, lineRange: lineRange, contentGroup: 3, match: match, theme: theme, runs: &runs)
            return
        }

        if let match = firstMatch(in: line, regex: orderedListRegex) {
            applyListIndent(line: line, lineRange: lineRange, contentGroup: 4, match: match, theme: theme, runs: &runs)
            return
        }
    }

    private static func parseInline(
        in text: String,
        targetRange: NSRange,
        theme: Theme,
        runs: inout [AttributeRun],
        interactive: inout [InteractiveRange]
    ) {
        let nsText = text as NSString
        guard let substringRange = Range(targetRange, in: text) else {
            return
        }

        let segment = String(text[substringRange])
        let segmentNS = segment as NSString
        let offset = targetRange.location

        var linkCoverage: [NSRange] = []

        for match in markdownLinkRegex.matches(in: segment, options: [], range: NSRange(location: 0, length: segmentNS.length)) {
            let full = translate(match.range(at: 0), by: offset)
            let urlRaw = segmentNS.substring(with: match.range(at: 2))
            guard let url = normalizedURL(from: urlRaw) else { continue }

            let labelLength = max(0, match.range(at: 2).location - match.range(at: 0).location - 1)
            if labelLength > 0 {
                let labelRange = NSRange(location: match.range(at: 0).location, length: labelLength)
                let absoluteLabelRange = translate(labelRange, by: offset)
                runs.append(AttributeRun(range: absoluteLabelRange, attributes: [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]))
            }

            interactive.append(InteractiveRange(range: full, kind: .link(url)))
            linkCoverage.append(full)
        }

        for match in bareURLRegex.matches(in: segment, options: [], range: NSRange(location: 0, length: segmentNS.length)) {
            let absolute = translate(match.range(at: 0), by: offset)
            guard !overlapsAny(absolute, in: linkCoverage) else { continue }
            let raw = segmentNS.substring(with: match.range(at: 0))
            guard let url = normalizedURL(from: raw) else { continue }

            runs.append(AttributeRun(range: absolute, attributes: [
                .foregroundColor: theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]))
            interactive.append(InteractiveRange(range: absolute, kind: .link(url)))
            linkCoverage.append(absolute)
        }

        applyInlineFont(regex: boldRegex, in: segment, offset: offset, trait: .traitBold, theme: theme, runs: &runs)
        applyInlineFont(regex: italicRegex, in: segment, offset: offset, trait: .traitItalic, theme: theme, runs: &runs)

        for match in strikeRegex.matches(in: segment, options: [], range: NSRange(location: 0, length: segmentNS.length)) {
            let inner = match.range(at: 1)
            guard inner.length > 0 else { continue }
            let absolute = translate(inner, by: offset)
            runs.append(AttributeRun(range: absolute, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        }
    }

    private static func applyInlineFont(
        regex: NSRegularExpression,
        in segment: String,
        offset: Int,
        trait: UIFontDescriptor.SymbolicTraits,
        theme: Theme,
        runs: inout [AttributeRun]
    ) {
        let nsSegment = segment as NSString
        let range = NSRange(location: 0, length: nsSegment.length)

        for match in regex.matches(in: segment, options: [], range: range) {
            let inner = match.range(at: 1)
            guard inner.length > 0 else { continue }
            let absolute = translate(inner, by: offset)
            let font = font(from: theme.baseFont, adding: trait)
            runs.append(AttributeRun(range: absolute, attributes: [.font: font]))
        }
    }

    private static func applyListIndent(
        line: String,
        lineRange: NSRange,
        contentGroup: Int,
        match: NSTextCheckingResult,
        theme: Theme,
        runs: inout [AttributeRun],
        prefixOverride: String? = nil
    ) {
        let nsLine = line as NSString
        let contentStart = match.range(at: contentGroup).location
        guard contentStart > 0 else { return }

        let prefix = prefixOverride ?? nsLine.substring(to: contentStart)
        let width = ceil((prefix as NSString).size(withAttributes: [.font: theme.baseFont]).width)

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = width

        runs.append(AttributeRun(range: lineRange, attributes: [.paragraphStyle: style]))
        let prefixLength = min(contentStart, lineRange.length)
        if prefixLength > 0 {
            let prefixRange = NSRange(location: lineRange.location, length: prefixLength)
            runs.append(AttributeRun(range: prefixRange, attributes: [.foregroundColor: theme.secondaryTextColor]))
        }
    }

    private static func requiresFullPassForStructuralEdit(_ edit: EditContext) -> Bool {
        let oldText = edit.oldText as NSString
        let safeRange = clamp(edit.range, to: oldText.length)
        let removed = safeRange.length > 0 ? oldText.substring(with: safeRange) : ""
        let combined = removed + edit.replacement

        if combined.contains("\n") {
            return true
        }

        if combined.contains(where: { structuralMarkdownCharacters.contains($0) }) {
            return true
        }

        let probeRange = NSRange(location: safeRange.location, length: min(max(1, safeRange.length), max(0, oldText.length - safeRange.location)))
        let lineRange = oldText.lineRange(for: probeRange)
        let prefixDistance = safeRange.location - lineRange.location
        if prefixDistance <= 6 {
            return true
        }

        return false
    }

    private static func font(from base: UIFont, adding trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = base.fontDescriptor.symbolicTraits.union(trait)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(combined) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static func firstMatch(in text: String, regex: NSRegularExpression) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func enumerateLines(in text: NSString, intersecting range: NSRange, using block: (NSRange) -> Void) {
        var cursor = range.location
        let end = range.location + range.length

        while cursor < end {
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            block(lineRange)
            let next = lineRange.location + lineRange.length
            if next <= cursor {
                break
            }
            cursor = next
        }
    }

    private static func overlapsAny(_ range: NSRange, in ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }

        if trimmed.lowercased().hasPrefix("www.") {
            return URL(string: "https://\(trimmed)")
        }

        return nil
    }

    private static func translate(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, range.location), length)
        let safeLength = min(max(0, range.length), max(0, length - location))
        return NSRange(location: location, length: safeLength)
    }

    private static func union(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        NSUnionRange(lhs, rhs)
    }

    private static let headerRegex = try! NSRegularExpression(pattern: #"^(\s{0,3}#{1,6}\s+).+$"#)
    private static let taskRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+\[( |x|X)\]\s+(.*)$"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+(.*)$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#)

    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\s)]+)\)"#)
    private static let bareURLRegex = try! NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s)]+"#)
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)([^*\n]+?)\*(?!\*)"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"~~(.+?)~~"#)
    private static let structuralMarkdownCharacters: Set<Character> = Set("#-*+[]()~")
}
