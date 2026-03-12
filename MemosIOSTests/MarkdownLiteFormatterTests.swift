import XCTest
import UIKit
@testable import Memos

final class MarkdownLiteFormatterTests: XCTestCase {
    func testToggleCheckboxFlipsState() {
        let text = "- [ ] Ship it\n- [x] Done"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)

        guard let firstCheckbox = rendered.interactiveRanges.first(where: {
            if case .checkbox = $0.kind { return true }
            return false
        }) else {
            XCTFail("Expected checkbox range")
            return
        }

        let nsText = text as NSString
        XCTAssertEqual(nsText.substring(with: firstCheckbox.range), "- [ ]")

        let toggled = MarkdownLiteFormatter.toggleCheckbox(
            in: text,
            at: firstCheckbox.range.location + 1,
            interactiveRanges: rendered.interactiveRanges
        )

        XCTAssertEqual(toggled, "- [x] Ship it\n- [x] Done")
    }

    func testMarkdownLinkNormalizesWWWURL() {
        let text = "[this is a link](www.example.com)"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)

        let links = rendered.interactiveRanges.compactMap { range -> URL? in
            if case let .link(url) = range.kind {
                return url
            }
            return nil
        }

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.absoluteString, "https://www.example.com")
    }

    func testShouldUseFullPassForMultilineReplacement() {
        let edit = MarkdownLiteFormatter.EditContext(
            oldText: "line one",
            range: NSRange(location: 4, length: 0),
            replacement: "\nline two"
        )

        XCTAssertTrue(MarkdownLiteFormatter.shouldUseFullPass(edit: edit))
    }

    func testShouldUseFullPassWhenDeletingListMarkerPrefix() {
        let edit = MarkdownLiteFormatter.EditContext(
            oldText: "- task one",
            range: NSRange(location: 0, length: 1),
            replacement: ""
        )

        XCTAssertTrue(MarkdownLiteFormatter.shouldUseFullPass(edit: edit))
    }

    func testHashtagCreatesInteractiveTagRange() {
        let text = "Review #house notes"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        guard let tagRange = rendered.interactiveRanges.first(where: {
            if case .tag = $0.kind { return true }
            return false
        }) else {
            XCTFail("Expected hashtag range")
            return
        }

        let extracted = MarkdownLiteFormatter.tag(
            at: tagRange.range.location + 1,
            interactiveRanges: rendered.interactiveRanges
        )

        XCTAssertEqual(extracted, "house")
    }

    func testHashtagRenderAddsTextItemTagAttribute() {
        let text = "Review #house notes"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let tagIdentifier = rendered.runs.first(where: {
            ($0.attributes[.textItemTag] as? String)?.hasPrefix("memos.tag:") == true
        })?.attributes[.textItemTag] as? String

        XCTAssertEqual(tagIdentifier, "memos.tag:house")
        XCTAssertEqual(
            MarkdownLiteFormatter.parseTextItemTag(tagIdentifier ?? ""),
            .tag("house")
        )
    }

    func testCheckboxRenderAddsTextItemTagAttribute() {
        let text = "- [ ] Ship it"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let checkboxIdentifier = rendered.runs.first(where: {
            ($0.attributes[.textItemTag] as? String) == "memos.checkbox"
        })?.attributes[.textItemTag] as? String

        XCTAssertEqual(checkboxIdentifier, "memos.checkbox")
        XCTAssertEqual(
            MarkdownLiteFormatter.parseTextItemTag(checkboxIdentifier ?? ""),
            .checkbox
        )
    }

    func testMarkdownLinkRenderAddsLinkAttribute() {
        let text = "[this is a link](www.example.com)"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let link = rendered.runs.first(where: { $0.attributes[.link] != nil })?.attributes[.link] as? URL

        XCTAssertEqual(link?.absoluteString, "https://www.example.com")
    }

    func testURLFragmentDoesNotCreateHashtagInteraction() {
        let text = "https://example.com/#fragment #todo"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let tags = rendered.interactiveRanges.compactMap { range -> String? in
            if case let .tag(tag) = range.kind {
                return tag
            }
            return nil
        }

        XCTAssertEqual(tags, ["todo"])
    }

    func testTaskIndentWidthMatchesForCheckedAndUncheckedItems() {
        let text = "- [ ] first line that wraps to prove head indent\n- [x] second line that wraps too"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let paragraphStyles = rendered.runs.compactMap { run -> NSParagraphStyle? in
            run.attributes[.paragraphStyle] as? NSParagraphStyle
        }

        XCTAssertGreaterThanOrEqual(paragraphStyles.count, 2)
        XCTAssertEqual(paragraphStyles[0].headIndent, paragraphStyles[1].headIndent, accuracy: 0.5)
    }

    func testTaskIndentMatchesPlainBulletIndent() {
        let text = "- plain bullet item that wraps nicely\n- [ ] checkbox item that wraps too"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let paragraphStyles = rendered.runs.compactMap { run -> NSParagraphStyle? in
            run.attributes[.paragraphStyle] as? NSParagraphStyle
        }

        XCTAssertGreaterThanOrEqual(paragraphStyles.count, 2)
        XCTAssertEqual(paragraphStyles[0].headIndent, paragraphStyles[1].headIndent, accuracy: 0.5)
    }

    func testTaskPrefixVisualWidthMatchesSharedListPrefixForUncheckedAndChecked() {
        let text = "- [ ] first task\n- [x] second task"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let nsText = text as NSString
        let taskRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+\[( |x|X)\]\s+(.*)$"#)
        let checkboxRanges = rendered.interactiveRanges.compactMap { range -> NSRange? in
            if case .checkbox = range.kind {
                return range.range
            }
            return nil
        }

        XCTAssertEqual(checkboxRanges.count, 2)

        for checkboxRange in checkboxRanges {
            let kernNumber = rendered.runs.first { run in
                run.range.location == checkboxRange.location
                    && run.range.length == checkboxRange.length
                    && run.attributes[.kern] != nil
            }?.attributes[.kern] as? NSNumber

            guard let kernNumber else {
                XCTFail("Expected kern run for checkbox range")
                continue
            }
            let kern = CGFloat(truncating: kernNumber)

            let lineRange = nsText.lineRange(for: NSRange(location: checkboxRange.location, length: 0))
            let line = nsText.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
            let nsLine = line as NSString

            guard let match = taskRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) else {
                XCTFail("Expected task regex match for checkbox line")
                continue
            }

            let indent = nsLine.substring(with: match.range(at: 1))
            let marker = nsLine.substring(with: match.range(at: 2))
            let targetListPrefix = "\(indent)\(marker) [ ] "
            let contentStart = match.range(at: 4).location
            let taskPrefix = nsLine.substring(to: contentStart)

            let targetListPrefixWidth = (targetListPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let taskWidth = (taskPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width
            let effectiveTaskWidth = taskWidth + (kern * CGFloat(max(1, checkboxRange.length - 1)))

            XCTAssertEqual(effectiveTaskWidth, targetListPrefixWidth, accuracy: 0.75)
        }
    }

    func testTaskRenderDoesNotInjectMonospacedCheckboxFont() {
        let text = "- [ ] todo one\n- [x] todo two"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let checkboxRanges = rendered.interactiveRanges.compactMap { range -> NSRange? in
            if case .checkbox = range.kind {
                return range.range
            }
            return nil
        }

        let hasMonospacedFontInCheckboxToken = rendered.runs.contains { run in
            guard let font = run.attributes[.font] as? UIFont else { return false }
            guard checkboxRanges.contains(where: { NSIntersectionRange(run.range, $0).length > 0 }) else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        }

        XCTAssertFalse(hasMonospacedFontInCheckboxToken)
    }

    func testPlainBulletUsesCheckboxCompatibleIndentWidth() {
        let text = "- plain bullet"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let headIndent = rendered.runs.compactMap { run -> CGFloat? in
            (run.attributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent
        }.first

        XCTAssertNotNil(headIndent)

        let targetPrefix = "- [ ] "
        let expected = ceil((targetPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width)
        XCTAssertEqual(headIndent, expected, accuracy: 0.5)
    }

    func testUnorderedFirstLineTextStartMatchesSharedListPrefix() {
        let text = "- plain bullet"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let nsText = text as NSString
        let listRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+(.*)$"#)

        guard let match = listRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            XCTFail("Expected unordered list regex match")
            return
        }

        let indent = nsText.substring(with: match.range(at: 1))
        let marker = nsText.substring(with: match.range(at: 2))
        let targetListPrefix = "\(indent)\(marker) [ ] "
        let targetListPrefixWidth = (targetListPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width

        let contentStart = match.range(at: 3).location
        let bulletPrefix = nsText.substring(to: contentStart)
        let bulletPrefixWidth = (bulletPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width

        let bridgeStart = contentStart - 1
        let bridgeRange = NSRange(location: bridgeStart, length: 1)
        let bridgeKernNumber = rendered.runs.first { run in
            run.range.location == bridgeRange.location
                && run.range.length == bridgeRange.length
                && run.attributes[.kern] != nil
        }?.attributes[.kern] as? NSNumber
        guard let bridgeKernNumber else {
            XCTFail("Expected unordered bridge kern run")
            return
        }
        let bridgeKern = CGFloat(truncating: bridgeKernNumber)

        guard let style = rendered.runs.compactMap({ $0.attributes[.paragraphStyle] as? NSParagraphStyle }).first else {
            XCTFail("Expected paragraph style run")
            return
        }
        XCTAssertGreaterThan(style.firstLineHeadIndent, 0)

        let firstLineTextStart = style.firstLineHeadIndent + bulletPrefixWidth + bridgeKern
        XCTAssertEqual(firstLineTextStart, targetListPrefixWidth, accuracy: 0.75)
    }

    func testOrderedListFirstLineTextStartMatchesUnorderedIndent() {
        let text = "1. ordered item"
        let theme = MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let nsText = text as NSString
        let orderedRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#)

        guard let match = orderedRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            XCTFail("Expected ordered list regex match")
            return
        }

        let indent = nsText.substring(with: match.range(at: 1))
        let targetListPrefix = "\(indent)- [ ] "
        let targetListPrefixWidth = (targetListPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width

        let contentStart = match.range(at: 4).location
        let orderedPrefix = nsText.substring(to: contentStart)
        let orderedPrefixWidth = (orderedPrefix as NSString).size(withAttributes: [.font: theme.baseFont]).width

        let bridgeStart = contentStart - 1
        let bridgeRange = NSRange(location: bridgeStart, length: 1)
        let bridgeKernNumber = rendered.runs.first { run in
            run.range.location == bridgeRange.location
                && run.range.length == bridgeRange.length
                && run.attributes[.kern] != nil
        }?.attributes[.kern] as? NSNumber
        guard let bridgeKernNumber else {
            XCTFail("Expected ordered bridge kern run")
            return
        }
        let bridgeKern = CGFloat(truncating: bridgeKernNumber)

        guard let style = rendered.runs.compactMap({ $0.attributes[.paragraphStyle] as? NSParagraphStyle }).first else {
            XCTFail("Expected paragraph style run")
            return
        }

        let firstLineTextStart = style.firstLineHeadIndent + orderedPrefixWidth + bridgeKern
        XCTAssertEqual(firstLineTextStart, targetListPrefixWidth, accuracy: 0.75)
    }

    func testInlineCodeRenderStylesFullSpanAndSuppressesNestedMarkdown() {
        let text = "Use `#todo` and #real"
        let theme = makeTheme()

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let nsText = text as NSString
        let codeRun = rendered.runs.first { $0.attributes[.backgroundColor] != nil }

        XCTAssertEqual(codeRun?.range, NSRange(location: 4, length: 7))
        XCTAssertEqual(nsText.substring(with: codeRun?.range ?? NSRange(location: 0, length: 0)), "`#todo`")

        let tags = rendered.interactiveRanges.compactMap { range -> String? in
            if case let .tag(tag) = range.kind {
                return tag
            }
            return nil
        }

        XCTAssertEqual(tags, ["real"])
    }

    func testFencedCodeBlockStylesFullBlockAndSuppressesNestedInteractions() {
        let text = "```swift\n#inside\n- [ ] task\n```\n#outside"
        let theme = makeTheme()

        let rendered = MarkdownLiteFormatter.fullRender(text: text, theme: theme)
        let nsText = text as NSString
        let expectedBlockText = "```swift\n#inside\n- [ ] task\n```\n"
        let expectedBlockRange = NSRange(location: 0, length: (expectedBlockText as NSString).length)
        let blockRun = rendered.runs.first { $0.range == expectedBlockRange && $0.attributes[.backgroundColor] != nil }

        XCTAssertNotNil(blockRun)
        XCTAssertEqual(nsText.substring(with: expectedBlockRange), expectedBlockText)

        let tags = rendered.interactiveRanges.compactMap { range -> String? in
            if case let .tag(tag) = range.kind {
                return tag
            }
            return nil
        }
        let checkboxCount = rendered.interactiveRanges.reduce(into: 0) { count, range in
            if case .checkbox = range.kind {
                count += 1
            }
        }

        XCTAssertEqual(tags, ["outside"])
        XCTAssertEqual(checkboxCount, 0)
    }

    private func makeTheme() -> MarkdownLiteFormatter.Theme {
        MarkdownLiteFormatter.Theme(
            baseFont: .systemFont(ofSize: 17),
            headerFont: .boldSystemFont(ofSize: 17),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .systemBlue
        )
    }
}
