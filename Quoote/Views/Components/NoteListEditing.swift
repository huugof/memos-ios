import SwiftUI
import UIKit

enum NoteTextViewListEditing {
    struct SpaceInsertionNormalization: Equatable {
        let lineRange: NSRange
        let replacementLine: String
    }

    static func normalizedSpaceInsertion(in text: String, caretLocation: Int) -> SpaceInsertionNormalization? {
        let nsText = text as NSString
        guard caretLocation >= 0, caretLocation <= nsText.length else { return nil }

        let lineRange = nsText.lineRange(for: NSRange(location: caretLocation, length: 0))
        let contentRange = lineContentRange(for: lineRange, in: nsText)
        let lineEnd = contentRange.location + contentRange.length
        guard caretLocation == lineEnd else { return nil }

        let rawLine = nsText.substring(with: contentRange)

        if let match = firstMatch(in: rawLine, regex: unorderedMarkerOnlyRegex) {
            return SpaceInsertionNormalization(
                lineRange: lineRange,
                replacementLine: "\(match[1])\(match[2])\t"
            )
        }

        if let match = firstMatch(in: rawLine, regex: orderedDelimitedMarkerOnlyRegex) {
            return SpaceInsertionNormalization(
                lineRange: lineRange,
                replacementLine: "\(match[1])\(match[2])\(match[3])\t"
            )
        }

        if let match = firstMatch(in: rawLine, regex: orderedBareMarkerOnlyRegex) {
            return SpaceInsertionNormalization(
                lineRange: lineRange,
                replacementLine: "\(match[1])\(match[2])\t"
            )
        }

        return nil
    }

    static func continuationPrefix(for line: String) -> String? {
        if let match = firstMatch(in: line, regex: taskContinuationRegex) {
            let indent = match[1]
            let marker = match[2]
            let content = match[3].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return "\(indent)\(marker) [ ] "
        }

        if let match = firstMatch(in: line, regex: unorderedContinuationRegex) {
            let indent = match[1]
            let marker = match[2]
            let separator = match[3]
            let content = match[4].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return "\(indent)\(marker)\(separator.contains("\t") ? "\t" : " ")"
        }

        if let match = firstMatch(in: line, regex: orderedContinuationRegex) {
            let indent = match[1]
            let number = Int(match[2]) ?? 1
            let delimiter = match[3]
            let separator = match[4]
            let content = match[5].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return "\(indent)\(number + 1)\(delimiter)\(separator.contains("\t") ? "\t" : " ")"
        }

        return nil
    }

    static func exitListReplacement(for line: String) -> String? {
        if let match = firstMatch(in: line, regex: taskExitRegex) {
            return match[1]
        }

        if let match = firstMatch(in: line, regex: unorderedExitRegex) {
            return match[1]
        }

        if let match = firstMatch(in: line, regex: orderedDelimitedExitRegex) {
            return match[1]
        }

        if let match = firstMatch(in: line, regex: orderedBareExitRegex) {
            return match[1]
        }

        return nil
    }

    static func normalizedTaskTab(in text: String, caretLocation: Int) -> SpaceInsertionNormalization? {
        let nsText = text as NSString
        guard caretLocation >= 0, caretLocation <= nsText.length else { return nil }

        let lineRange = nsText.lineRange(for: NSRange(location: caretLocation, length: 0))
        let contentRange = lineContentRange(for: lineRange, in: nsText)
        let rawLine = nsText.substring(with: contentRange)

        guard rawLine.contains("\t"),
              firstMatch(in: rawLine, regex: taskTabRegex) != nil else {
            return nil
        }

        let normalized = rawLine.replacingOccurrences(of: "\t", with: " ")
        return SpaceInsertionNormalization(lineRange: lineRange, replacementLine: normalized)
    }

    static func lineContentRange(for lineRange: NSRange, in text: NSString) -> NSRange {
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

    private static func firstMatch(in text: String, regex: NSRegularExpression) -> [String]? {
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

    private static let taskTabRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\t\[(?: |x|X)\]"#)
    private static let taskContinuationRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+\[(?: |x|X)\]\s+(.*)$"#)
    private static let unorderedContinuationRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])(\t|\s+)(.*)$"#)
    private static let orderedContinuationRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)]?)(\t|\s+)(.*)$"#)

    private static let taskExitRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+\[(?: |x|X)\]\s*$"#)
    private static let unorderedExitRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])(?:\t|\s*)$"#)
    private static let orderedDelimitedExitRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])\s*$"#)
    private static let orderedBareExitRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)(?:\t|\s+)$"#)

    private static let unorderedMarkerOnlyRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])$"#)
    private static let orderedDelimitedMarkerOnlyRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])$"#)
    private static let orderedBareMarkerOnlyRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)$"#)
}
