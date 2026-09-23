import Foundation

enum TagExtractor {
    static let regex = try! NSRegularExpression(pattern: #"#([A-Za-z0-9_-]+)"#)

    static func tags(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { continue }
            let tag = String(text[r]).lowercased()
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    static func tags(inTexts texts: [String]) -> [String] {
        texts.flatMap { tags(in: $0) }
    }
}
