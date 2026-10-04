import XCTest
@testable import Quoote

final class NoteAttachmentsTests: XCTestCase {

    private func image(_ target: String, name: String? = nil) -> NoteAttachment {
        NoteAttachment(target: target, name: name ?? (target as NSString).lastPathComponent, kind: .image)
    }

    private func file(_ target: String, name: String? = nil) -> NoteAttachment {
        NoteAttachment(target: target, name: name ?? (target as NSString).lastPathComponent, kind: .file)
    }

    // MARK: Wikilink embeds

    func testWikilinkImageKeepsItsNameAsWritten() {
        XCTAssertEqual(NoteAttachments.parse("![[photo 1.jpg]]"), [image("photo 1.jpg")])
    }

    func testWikilinkPathKeepsFoldersInTargetAndNamesTheLastComponent() {
        XCTAssertEqual(
            NoteAttachments.parse("![[attachments/trip/a.png]]"),
            [NoteAttachment(target: "attachments/trip/a.png", name: "a.png", kind: .image)]
        )
    }

    func testWikilinkSizeAndPageSuffixesAreNotPartOfTheTarget() {
        XCTAssertEqual(NoteAttachments.parse("![[a.png|200]]"), [image("a.png")])
        XCTAssertEqual(NoteAttachments.parse("![[a.png|200x100]]"), [image("a.png")])
        XCTAssertEqual(NoteAttachments.parse("![[doc.pdf#page=3]]"), [file("doc.pdf")])
    }

    func testWikilinkExtensionsAreMatchedCaseInsensitively() {
        XCTAssertEqual(NoteAttachments.parse("![[IMG_0001.JPG]]"), [image("IMG_0001.JPG")])
        XCTAssertEqual(NoteAttachments.parse("![[Scan.PDF]]"), [file("Scan.PDF")])
    }

    func testWikilinkToANoteOrADottedNoteNameIsNotAnAttachment() {
        XCTAssertEqual(NoteAttachments.parse("![[Some Note]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Some Note#Heading]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Meeting 10.3]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Plan.md]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Plan.markdown]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[]]"), [])
    }

    func testWikilinkToOtherFilesIsAFile() {
        XCTAssertEqual(NoteAttachments.parse("![[song.mp3]]"), [file("song.mp3")])
        XCTAssertEqual(NoteAttachments.parse("![[logo.svg]]"), [file("logo.svg")])
    }

    // MARK: Markdown images

    func testMarkdownImageWithAnAbsoluteURLKeepsTheURLAsTarget() {
        let url = "https://memos.example.com/file/attachments/abc/image.jpg"
        XCTAssertEqual(NoteAttachments.parse("![](\(url))"), [image(url, name: "image.jpg")])
    }

    func testMarkdownImageWithARelativePathIsPercentDecoded() {
        XCTAssertEqual(
            NoteAttachments.parse("![](attachments/my%20pic.png)"),
            [NoteAttachment(target: "attachments/my pic.png", name: "my pic.png", kind: .image)]
        )
    }

    func testMarkdownImageInAngleBracketsMayContainSpaces() {
        XCTAssertEqual(NoteAttachments.parse("![alt](<my pic.png>)"), [image("my pic.png")])
    }

    func testMarkdownImageTitleIsNotPartOfTheTarget() {
        XCTAssertEqual(NoteAttachments.parse("![alt](pic.png \"A caption\")"), [image("pic.png")])
    }

    func testMarkdownImageWithANonHTTPSchemeIsIgnored() {
        XCTAssertEqual(NoteAttachments.parse("![](data:image/png;base64,AAAA)"), [])
        XCTAssertEqual(NoteAttachments.parse("![](file:///tmp/a.png)"), [])
        XCTAssertEqual(NoteAttachments.parse("![]()"), [])
    }

    func testMarkdownImageKindFollowsTheExtensionAndDefaultsToImage() {
        XCTAssertEqual(NoteAttachments.parse("![](https://x.test/report.pdf)").map(\.kind), [.file])
        XCTAssertEqual(NoteAttachments.parse("![](https://x.test/photo)").map(\.kind), [.image])
        XCTAssertEqual(NoteAttachments.parse("![](https://x.test/Photo.HEIC)").map(\.kind), [.image])
    }

    func testMarkdownImageNameDropsTheQueryAndIsPercentDecoded() {
        XCTAssertEqual(
            NoteAttachments.parse("![](https://x.test/a/b%20c.png?size=2)").map(\.name),
            ["b c.png"]
        )
    }

    // MARK: Memos file links

    func testLinkToAMemosFileIsAnAttachmentNamedByItsText() {
        let url = "https://memos.example.com/file/attachments/u/Report.pdf"
        XCTAssertEqual(
            NoteAttachments.parse("[Report.pdf](\(url))"),
            [NoteAttachment(target: url, name: "Report.pdf", kind: .file)]
        )
    }

    func testLinkToAMemosImageFileIsAnImage() {
        XCTAssertEqual(
            NoteAttachments.parse("[pic.jpg](/file/attachments/u/pic.jpg)"),
            [NoteAttachment(target: "/file/attachments/u/pic.jpg", name: "pic.jpg", kind: .image)]
        )
    }

    func testLinkToTheOlderMemosFilePathIsAnAttachment() {
        XCTAssertEqual(
            NoteAttachments.parse("[x.pdf](/o/r/12/x.pdf)"),
            [NoteAttachment(target: "/o/r/12/x.pdf", name: "x.pdf", kind: .file)]
        )
    }

    func testLinkWithSpacesInTheFilenameIsKeptWhole() {
        // Quoote writes the uploaded filename raw, so a name with spaces is a destination with spaces.
        let url = "https://m.example.com/file/attachments/u/My Doc.pdf"
        XCTAssertEqual(
            NoteAttachments.parse("[My Doc.pdf](\(url))"),
            [NoteAttachment(target: url, name: "My Doc.pdf", kind: .file)]
        )
    }

    func testEmptyLinkTextFallsBackToTheFilename() {
        XCTAssertEqual(NoteAttachments.parse("[](/file/attachments/u/a.jpg)").map(\.name), ["a.jpg"])
    }

    func testALinkWhoseFilenameHasParenthesesIsKeptWhole() {
        // "Scan (2).pdf" is what a second download of the same file is called, and Quoote writes the name raw.
        let url = "https://m.example.com/file/attachments/u/Scan (2).pdf"
        XCTAssertEqual(
            NoteAttachments.parse("[Scan (2).pdf](\(url))"),
            [NoteAttachment(target: url, name: "Scan (2).pdf", kind: .file)]
        )
    }

    func testAMarkdownImageWhoseNameHasParenthesesIsKeptWhole() {
        let url = "https://m.example.com/file/attachments/u/photo(1).png"
        XCTAssertEqual(NoteAttachments.parse("![](\(url))"), [image(url, name: "photo(1).png")])
    }

    func testOrdinaryLinksAreNotAttachments() {
        XCTAssertEqual(NoteAttachments.parse("[site](https://example.com/page)"), [])
        XCTAssertEqual(NoteAttachments.parse("[note](folder/note.md)"), [])
        XCTAssertEqual(NoteAttachments.parse("[mail](mailto:a@b.test)"), [])
    }

    func testAnImageWrappedInALinkIsOneImage() {
        let text = "[![](/file/attachments/u/a.jpg)](/file/attachments/u/a.jpg)"
        XCTAssertEqual(NoteAttachments.parse(text), [image("/file/attachments/u/a.jpg")])
    }

    // MARK: Order, duplicates, text

    func testAttachmentsComeInDocumentOrderAcrossSyntaxes() {
        let text = """
        ![[first.png]] some words
        [second.pdf](/file/attachments/u/second.pdf)
        ![](https://m.example.com/file/attachments/u/third.jpg)
        """
        XCTAssertEqual(NoteAttachments.parse(text).map(\.name), ["first.png", "second.pdf", "third.jpg"])
    }

    func testDuplicatesCollapseToTheFirst() {
        XCTAssertEqual(NoteAttachments.parse("![[a.png]] and again ![[a.png]]"), [image("a.png")])
    }

    func testAnAbsoluteAndARelativeLinkToTheSameMemosFileAreOne() {
        let text = "![](https://m.example.com/file/attachments/u/a.jpg)\n[a.jpg](/file/attachments/u/a.jpg)"
        XCTAssertEqual(NoteAttachments.parse(text).count, 1)
    }

    func testEmojiAndNonLatinTextBeforeAnEmbedDoNotShiftIt() {
        let text = "😀 日本語のメモ 👨‍👩‍👧 ![[写真.jpg]] — [r.pdf](/file/attachments/u/r.pdf)"
        XCTAssertEqual(
            NoteAttachments.parse(text),
            [image("写真.jpg"), file("/file/attachments/u/r.pdf", name: "r.pdf")]
        )
    }

    func testTextWithoutBracketsHasNoAttachments() {
        XCTAssertEqual(NoteAttachments.parse(""), [])
        XCTAssertEqual(NoteAttachments.parse("just words, no embeds"), [])
    }

    // MARK: Identity and classification

    func testIdentityIgnoresHostEncodingQueryAndFragment() {
        let a = file("/file/attachments/u/My%20Doc.pdf")
        let b = file("https://m.example.com/file/attachments/u/My Doc.pdf?x=1#top")
        XCTAssertEqual(a.identity, b.identity)
        XCTAssertEqual(file("Docs/a.pdf").identity, "Docs/a.pdf")
    }

    func testRemoteMeansAURLOrAMemosPath() {
        XCTAssertTrue(file("https://x.test/a.png").isRemote)
        XCTAssertTrue(file("HTTP://x.test/a.png").isRemote)
        XCTAssertTrue(file("/file/attachments/u/a.png").isRemote)
        XCTAssertTrue(file("/o/r/1/a.png").isRemote)
        XCTAssertFalse(file("a.png").isRemote)
        XCTAssertFalse(file("/a.png").isRemote)
        XCTAssertFalse(file("attachments/a.png").isRemote)
    }

    // MARK: merged / tile

    func testMergedKeepsTheFirstListFirstAndDropsDuplicates() {
        let text = [image("/file/attachments/u/a.jpg")]
        let server = [image("https://m.example.com/file/attachments/u/a.jpg"), file("/file/attachments/u/b.pdf")]
        XCTAssertEqual(NoteAttachments.merged(text, server).map(\.name), ["a.jpg", "b.pdf"])
    }

    func testTileOfNothingIsNil() {
        XCTAssertNil(NoteAttachments.tile(from: []))
    }

    func testTilePrefersTheFirstImageAndCountsTheRest() {
        let tile = NoteAttachments.tile(from: [file("a.pdf"), image("b.png"), image("c.png")])
        XCTAssertEqual(tile, NoteAttachmentTile(attachment: image("b.png"), extra: 2))
    }

    func testTileOfOnlyFilesIsTheFirstFile() {
        let tile = NoteAttachments.tile(from: [file("a.pdf"), file("b.pdf")])
        XCTAssertEqual(tile, NoteAttachmentTile(attachment: file("a.pdf"), extra: 1))
    }

    func testTileOfASingleAttachmentHasNoExtras() {
        XCTAssertEqual(NoteAttachments.tile(from: [image("a.png")])?.extra, 0)
    }

    // MARK: Excerpt support

    func testRemovingMemosFileLinksKeepsOrdinaryLinks() {
        let text = "see [Report.pdf](https://m.example.com/file/attachments/u/Report.pdf) and [site](https://example.com)"
        XCTAssertEqual(NoteAttachments.removingMemosFileLinks(from: text), "see  and [site](https://example.com)")
    }

    // MARK: Server list

    func testServerListReadsTheModernAttachmentsArray() {
        let memo: [String: Any] = [
            "attachments": [
                ["name": "attachments/abc", "filename": "image.jpg", "type": "image/jpeg"],
                ["name": "attachments/def", "filename": "Report.pdf", "type": "application/pdf"],
            ],
        ]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: memo, fallback: [:]),
            [
                NoteAttachment(target: "/file/attachments/abc/image.jpg", name: "image.jpg", kind: .image),
                NoteAttachment(target: "/file/attachments/def/Report.pdf", name: "Report.pdf", kind: .file),
            ]
        )
    }

    func testServerListReadsOlderResourcesAndNumericIDs() {
        let memo: [String: Any] = [
            "resources": [
                ["name": "resources/7", "filename": "a.png", "type": "image/png"],
                ["id": 12, "filename": "b.png", "type": "image/png"],
                ["id": "13", "filename": "c.pdf", "type": "application/pdf"],
            ],
        ]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: memo, fallback: [:])?.map(\.target),
            ["/file/resources/7/a.png", "/o/r/12/b.png", "/o/r/13/c.pdf"]
        )
    }

    func testServerListSkipsElementsWithoutAFilenameOrAnAddress() {
        let memo: [String: Any] = [
            "attachments": [
                ["name": "attachments/x", "filename": "  "],
                ["name": "attachments/y"],
                ["filename": "orphan.png"],
            ],
        ]
        XCTAssertEqual(NoteAttachments.fromServerList(memo: memo, fallback: [:]), [])
    }

    func testServerListTreatsSVGAndUnknownTypesAsFiles() {
        let memo: [String: Any] = [
            "attachments": [
                ["name": "attachments/a", "filename": "logo.svg", "type": "image/svg+xml"],
                ["name": "attachments/b", "filename": "mystery", "type": ""],
                ["name": "attachments/c", "filename": "Shot.PNG", "type": "IMAGE/PNG"],
            ],
        ]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: memo, fallback: [:])?.map(\.kind),
            [.file, .file, .image]
        )
    }

    func testServerListIsNilWhenTheResponseHasNoListAndEmptyWhenTheListIsEmpty() {
        XCTAssertNil(NoteAttachments.fromServerList(memo: ["content": "hi"], fallback: [:]))
        XCTAssertNil(NoteAttachments.fromServerList(memo: ["attachments": 2], fallback: [:]))
        XCTAssertEqual(NoteAttachments.fromServerList(memo: ["attachments": [[String: Any]]()], fallback: [:]), [])
    }

    func testServerListFallsBackToThePayloadAndTheEnvelope() {
        let element: [String: Any] = ["name": "attachments/a", "filename": "a.png", "type": "image/png"]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: ["payload": ["attachments": [element]]], fallback: [:])?.count, 1
        )
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: [:], fallback: ["attachments": [element]])?.count, 1
        )
    }
}
