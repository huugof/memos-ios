import Foundation
import UIKit

struct MarkdownLiteFormatter {
    enum TextItemTag: Equatable {
        case checkbox
        case tag(String)
    }

    struct Theme {
        let baseFont: UIFont
        let headerFont: UIFont
        let textColor: UIColor
        let secondaryTextColor: UIColor
        let linkColor: UIColor
        let codeBackgroundColor: UIColor

        init(
            baseFont: UIFont,
            headerFont: UIFont,
            textColor: UIColor,
            secondaryTextColor: UIColor,
            linkColor: UIColor,
            codeBackgroundColor: UIColor = .secondarySystemBackground
        ) {
            self.baseFont = baseFont
            self.headerFont = headerFont
            self.textColor = textColor
            self.secondaryTextColor = secondaryTextColor
            self.linkColor = linkColor
            self.codeBackgroundColor = codeBackgroundColor
        }

        static func `default`(for textView: UITextView) -> Theme {
            let base = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let header = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
            return Theme(
                baseFont: base,
                headerFont: header,
                textColor: .label,
                secondaryTextColor: .secondaryLabel,
                linkColor: textView.tintColor,
                codeBackgroundColor: .secondarySystemBackground
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
        case tag(String)
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
    private static let checkboxTextItemIdentifier = "memos.checkbox"
    private static let tagTextItemPrefix = "memos.tag:"

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
            case .tag:
                return false
            }
        }) else {
            return nil
        }

        guard case .checkbox = hit.kind else {
            return nil
        }

        guard let (checkboxRange, isChecked) = checkboxRange(in: nsText, around: hit.range) else {
            return nil
        }

        let replacement = isChecked ? "[ ]" : "[x]"
        return nsText.replacingCharacters(in: checkboxRange, with: replacement)
    }

    static func url(at characterIndex: Int, interactiveRanges: [InteractiveRange]) -> URL? {
        guard let hit = interactiveRanges.first(where: {
            switch $0.kind {
            case .link:
                return NSLocationInRange(characterIndex, $0.range)
            case .checkbox:
                return false
            case .tag:
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

    static func tag(at characterIndex: Int, interactiveRanges: [InteractiveRange]) -> String? {
        guard let hit = interactiveRanges.first(where: {
            switch $0.kind {
            case .tag:
                return NSLocationInRange(characterIndex, $0.range)
            case .checkbox, .link:
                return false
            }
        }) else {
            return nil
        }

        if case let .tag(tag) = hit.kind {
            return tag
        }
        return nil
    }

    static func parseTextItemTag(_ identifier: String) -> TextItemTag? {
        if identifier == checkboxTextItemIdentifier {
            return .checkbox
        }

        guard identifier.hasPrefix(tagTextItemPrefix) else {
            return nil
        }

        let tag = String(identifier.dropFirst(tagTextItemPrefix.count))
        guard !tag.isEmpty else { return nil }
        return .tag(tag)
    }

    private static func render(text: String, nsText: NSString, in targetRange: NSRange, theme: Theme) -> RenderResult {
        guard targetRange.length > 0 else {
            return RenderResult(runs: [], interactiveRanges: [])
        }

        var runs: [AttributeRun] = []
        var interactive: [InteractiveRange] = []
        let codeBlockRanges = fencedCodeBlockRanges(in: nsText)
        let inlineCodeRanges = inlineCodeRanges(in: text, excluding: codeBlockRanges)
        let protectedRanges = codeBlockRanges + inlineCodeRanges

        for codeBlockRange in codeBlockRanges {
            guard let visibleRange = intersection(codeBlockRange, targetRange) else {
                continue
            }
            runs.append(AttributeRun(range: visibleRange, attributes: codeAttributes(theme: theme)))
        }

        for inlineCodeRange in inlineCodeRanges {
            guard let visibleRange = intersection(inlineCodeRange, targetRange) else {
                continue
            }
            runs.append(AttributeRun(range: visibleRange, attributes: codeAttributes(theme: theme)))
        }

        enumerateLines(in: nsText, intersecting: targetRange) { lineRange in
            guard !overlapsAny(lineRange, in: codeBlockRanges) else { return }
            let line = nsText.substring(with: lineRange)
            parseLine(line, lineRange: lineRange, theme: theme, runs: &runs, interactive: &interactive)
        }

        parseInline(
            in: text,
            targetRange: targetRange,
            excluding: protectedRanges,
            theme: theme,
            runs: &runs,
            interactive: &interactive
        )
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
            let checkedRange = match.range(at: 3)
            let isChecked = nsLine.substring(with: checkedRange).lowercased() == "x"
            let contentRange = match.range(at: 4)
            let contentStart = min(nsLine.length, max(0, contentRange.location))

            let markerRange = match.range(at: 2)
            let checkboxTokenStart = markerRange.location
            let checkboxTokenEnd = min(nsLine.length, checkedRange.location + 2)
            let checkboxTokenLength = max(0, checkboxTokenEnd - checkboxTokenStart)
            guard checkboxTokenLength > 0 else { return }
            let checkboxTokenRange = NSRange(location: checkboxTokenStart, length: checkboxTokenLength)
            let absoluteCheckboxTokenRange = NSRange(
                location: lineRange.location + checkboxTokenRange.location,
                length: checkboxTokenRange.length
            )

            let targetListPrefix = "\(indent)\(marker) [ ] "
            let taskPrefix = nsLine.substring(to: contentStart)
            let targetListPrefixWidth = (targetListPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let targetListHeadIndent = ceil(targetListPrefixWidth)
            let taskPrefixWidth = (taskPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let kerningGaps = CGFloat(max(1, checkboxTokenRange.length - 1))
            let taskTokenKerning = (targetListPrefixWidth - taskPrefixWidth) / kerningGaps
            applyListIndent(
                line: line,
                lineRange: lineRange,
                contentGroup: 4,
                match: match,
                theme: theme,
                runs: &runs,
                headIndentOverride: targetListHeadIndent
            )

            interactive.append(InteractiveRange(range: absoluteCheckboxTokenRange, kind: .checkbox(isChecked: isChecked)))
            runs.append(AttributeRun(range: absoluteCheckboxTokenRange, attributes: [
                .foregroundColor: UIColor.clear,
                .kern: taskTokenKerning,
                .textItemTag: checkboxTextItemIdentifier
            ]))

            if isChecked {
                if contentRange.length > 0 {
                    let absoluteContentRange = NSRange(location: lineRange.location + contentRange.location, length: contentRange.length)
                    runs.append(AttributeRun(range: absoluteContentRange, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
                }
            }
            return
        }

        if let match = firstMatch(in: line, regex: unorderedListRegex) {
            let indent = nsLine.substring(with: match.range(at: 1))
            let marker = nsLine.substring(with: match.range(at: 2))
            let targetListPrefix = "\(indent)\(marker) [ ] "
            let targetListPrefixWidth = (targetListPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let targetListHeadIndent = ceil(targetListPrefixWidth)
            let contentStart = match.range(at: 3).location
            let bulletPrefix = nsLine.substring(to: contentStart)
            let bulletPrefixWidth = (bulletPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let bridgeKerning = max(0, targetListPrefixWidth - bulletPrefixWidth)
            let markerShift = bridgeKerning * listMarkerShiftRatio
            let adjustedBridgeKerning = max(0, bridgeKerning - markerShift)
            applyListIndent(
                line: line,
                lineRange: lineRange,
                contentGroup: 3,
                match: match,
                theme: theme,
                runs: &runs,
                headIndentOverride: targetListHeadIndent,
                firstLineHeadIndentOverride: markerShift
            )
            if adjustedBridgeKerning > 0, contentStart > 0, contentStart < nsLine.length {
                let bridgeStart = contentStart - 1
                let bridgeRange = NSRange(location: lineRange.location + bridgeStart, length: 1)
                runs.append(AttributeRun(range: bridgeRange, attributes: [.kern: adjustedBridgeKerning]))
            }
            return
        }

        if let match = firstMatch(in: line, regex: orderedListRegex) {
            let indent = nsLine.substring(with: match.range(at: 1))
            let targetListPrefix = "\(indent)- [ ] "
            let targetListPrefixWidth = (targetListPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let targetListHeadIndent = ceil(targetListPrefixWidth)
            let contentStart = match.range(at: 4).location
            let orderedPrefix = nsLine.substring(to: contentStart)
            let orderedPrefixWidth = (orderedPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let bridgeDelta = targetListPrefixWidth - orderedPrefixWidth
            let markerShift = max(0, bridgeDelta) * listMarkerShiftRatio
            let adjustedBridgeKerning = bridgeDelta - markerShift
            applyListIndent(
                line: line,
                lineRange: lineRange,
                contentGroup: 4,
                match: match,
                theme: theme,
                runs: &runs,
                headIndentOverride: targetListHeadIndent,
                firstLineHeadIndentOverride: markerShift
            )
            if adjustedBridgeKerning != 0, contentStart > 0, contentStart < nsLine.length {
                let bridgeStart = contentStart - 1
                let bridgeRange = NSRange(location: lineRange.location + bridgeStart, length: 1)
                runs.append(AttributeRun(range: bridgeRange, attributes: [.kern: adjustedBridgeKerning]))
            }
            return
        }
    }

    private static func parseInline(
        in text: String,
        targetRange: NSRange,
        excluding protectedRanges: [NSRange],
        theme: Theme,
        runs: inout [AttributeRun],
        interactive: inout [InteractiveRange]
    ) {
        for segmentRange in uncoveredRanges(within: targetRange, excluding: protectedRanges) {
            guard let substringRange = Range(segmentRange, in: text) else {
                continue
            }

            let segment = String(text[substringRange])
            let segmentNS = segment as NSString
            let offset = segmentRange.location

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

                runs.append(AttributeRun(range: full, attributes: [.link: url]))
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
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ]))
                interactive.append(InteractiveRange(range: absolute, kind: .link(url)))
                linkCoverage.append(absolute)
            }

            for match in hashtagRegex.matches(in: segment, options: [], range: NSRange(location: 0, length: segmentNS.length)) {
                guard match.numberOfRanges > 1 else { continue }

                let full = translate(match.range(at: 0), by: offset)
                guard !overlapsAny(full, in: linkCoverage) else { continue }

                let rawTag = segmentNS.substring(with: match.range(at: 1))
                guard let normalizedTag = normalizedTag(from: rawTag) else { continue }

                let tagFont = font(from: theme.baseFont, adding: .traitBold)
                runs.append(AttributeRun(range: full, attributes: [
                    .foregroundColor: theme.linkColor,
                    .font: tagFont,
                    .textItemTag: "\(tagTextItemPrefix)\(normalizedTag)"
                ]))
                interactive.append(InteractiveRange(range: full, kind: .tag(normalizedTag)))
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

    private static func codeAttributes(theme: Theme) -> [NSAttributedString.Key: Any] {
        [
            .font: codeFont(from: theme.baseFont),
            .backgroundColor: theme.codeBackgroundColor
        ]
    }

    private static func applyListIndent(
        line: String,
        lineRange: NSRange,
        contentGroup: Int,
        match: NSTextCheckingResult,
        theme: Theme,
        runs: inout [AttributeRun],
        prefixOverride: String? = nil,
        headIndentOverride: CGFloat? = nil,
        firstLineHeadIndentOverride: CGFloat? = nil
    ) {
        let nsLine = line as NSString
        let contentStart = match.range(at: contentGroup).location
        guard contentStart > 0 else { return }

        let prefix = prefixOverride ?? nsLine.substring(to: contentStart)
        let width = headIndentOverride ?? ceil((prefix as NSString).size(withAttributes: [.font: theme.baseFont]).width)

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLineHeadIndentOverride ?? 0
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

    private static func codeFont(from base: UIFont) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: .regular)
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

    private static func fencedCodeBlockRanges(in text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var openStart: Int?
        let fullRange = NSRange(location: 0, length: text.length)

        enumerateLines(in: text, intersecting: fullRange) { lineRange in
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)

            if openStart == nil {
                if openingFenceRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                    openStart = lineRange.location
                }
                return
            }

            if closingFenceRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) != nil,
               let blockStart = openStart {
                let blockEnd = lineRange.location + lineRange.length
                ranges.append(NSRange(location: blockStart, length: blockEnd - blockStart))
                openStart = nil
            }
        }

        if let openStart {
            ranges.append(NSRange(location: openStart, length: text.length - openStart))
        }

        return ranges
    }

    private static func inlineCodeRanges(in text: String, excluding blockedRanges: [NSRange]) -> [NSRange] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var matches: [NSRange] = []

        for segmentRange in uncoveredRanges(within: fullRange, excluding: blockedRanges) {
            guard let substringRange = Range(segmentRange, in: text) else {
                continue
            }

            let segment = String(text[substringRange])
            let segmentNS = segment as NSString
            for match in inlineCodeRegex.matches(in: segment, options: [], range: NSRange(location: 0, length: segmentNS.length)) {
                let full = translate(match.range(at: 0), by: segmentRange.location)
                guard full.length > 2 else { continue }
                matches.append(full)
            }
        }

        return matches
    }

    private static func uncoveredRanges(within targetRange: NSRange, excluding excludedRanges: [NSRange]) -> [NSRange] {
        guard targetRange.length > 0 else { return [] }

        let intersections = excludedRanges.compactMap { intersection($0, targetRange) }.sorted { lhs, rhs in
            if lhs.location != rhs.location {
                return lhs.location < rhs.location
            }
            return lhs.length < rhs.length
        }

        var uncovered: [NSRange] = []
        var cursor = targetRange.location
        let end = targetRange.location + targetRange.length

        for blockedRange in intersections {
            if blockedRange.location > cursor {
                uncovered.append(NSRange(location: cursor, length: blockedRange.location - cursor))
            }
            cursor = max(cursor, blockedRange.location + blockedRange.length)
            if cursor >= end {
                break
            }
        }

        if cursor < end {
            uncovered.append(NSRange(location: cursor, length: end - cursor))
        }

        return uncovered
    }

    private static func overlapsAny(_ range: NSRange, in ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func intersection(_ lhs: NSRange, _ rhs: NSRange) -> NSRange? {
        let overlap = NSIntersectionRange(lhs, rhs)
        guard overlap.length > 0 else { return nil }
        return overlap
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

    private static func normalizedTag(from raw: String) -> String? {
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

    private static func translate(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, range.location), length)
        let safeLength = min(max(0, range.length), max(0, length - location))
        return NSRange(location: location, length: safeLength)
    }

    private static func checkboxRange(in text: NSString, around interactiveRange: NSRange) -> (NSRange, Bool)? {
        guard text.length > 0 else { return nil }
        let probeLocation = min(max(0, interactiveRange.location), text.length - 1)
        let lineRange = text.lineRange(for: NSRange(location: probeLocation, length: 0))
        let line = text.substring(with: lineRange)
        let nsLine = line as NSString

        guard let match = firstMatch(in: line, regex: taskRegex) else {
            return nil
        }

        let checkedRange = match.range(at: 3)
        guard checkedRange.location != NSNotFound, checkedRange.length == 1 else {
            return nil
        }

        let checkboxRangeInLine = NSRange(location: max(0, checkedRange.location - 1), length: 3)
        let absoluteCheckboxRange = NSRange(
            location: lineRange.location + checkboxRangeInLine.location,
            length: checkboxRangeInLine.length
        )
        let isChecked = nsLine.substring(with: checkedRange).lowercased() == "x"
        return (absoluteCheckboxRange, isChecked)
    }

    private static func union(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        NSUnionRange(lhs, rhs)
    }

    private static let headerRegex = try! NSRegularExpression(pattern: #"^(\s{0,3}#{1,6}\s+).+$"#)
    private static let taskRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+\[( |x|X)\]\s+(.*)$"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+(.*)$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#)
    private static let listMarkerShiftRatio: CGFloat = 0.35

    private static let openingFenceRegex = try! NSRegularExpression(pattern: #"^\s*```(?:\s*\S.*)?$"#)
    private static let closingFenceRegex = try! NSRegularExpression(pattern: #"^\s*```\s*$"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"(?<!`)`[^`\n]+`(?!`)"#)

    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\s)]+)\)"#)
    private static let bareURLRegex = try! NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s)]+"#)
    private static let hashtagRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_/-])#([A-Za-z0-9_-]+)"#)
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)([^*\n]+?)\*(?!\*)"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"~~(.+?)~~"#)
    private static let structuralMarkdownCharacters: Set<Character> = Set("#-*+[]()~`")
}
