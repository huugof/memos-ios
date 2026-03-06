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
}
