import XCTest
import UIKit
@testable import MemoChat

final class AttachmentMarkdownBuilderTests: XCTestCase {

    private func image() -> UIImage { UIImage() }

    func testVaultImageLinksAsWikilinkWhenDestinationIsVault() {
        var image = PendingImage(image: image())
        image.uploadedURL = "Attachments/pic.jpg"
        image.vaultPath = "Attachments/pic.jpg"
        image.isUploading = false

        let parts = AttachmentMarkdownBuilder.build(images: [image], files: [], currentDestination: .vault)

        XCTAssertEqual(parts, ["![[pic.jpg]]"])
    }

    func testServerImageLinksAsMarkdownImageWhenDestinationIsMemos() {
        var image = PendingImage(image: image())
        image.uploadedURL = "https://example.com/file/abc"
        image.isUploading = false

        let parts = AttachmentMarkdownBuilder.build(images: [image], files: [], currentDestination: .memos)

        XCTAssertEqual(parts, ["![](https://example.com/file/abc)"])
    }

    func testVaultImageIsDroppedWhenCurrentDestinationIsMemos() {
        // Regression for Minor 2: switching destination between picking an
        // image and sending must not mis-link it as a server URL.
        var image = PendingImage(image: image())
        image.uploadedURL = "Attachments/pic.jpg"
        image.vaultPath = "Attachments/pic.jpg"
        image.isUploading = false

        let parts = AttachmentMarkdownBuilder.build(images: [image], files: [], currentDestination: .memos)

        XCTAssertTrue(parts.isEmpty)
    }

    func testServerImageIsDroppedWhenCurrentDestinationIsVault() {
        var image = PendingImage(image: image())
        image.uploadedURL = "https://example.com/file/abc"
        image.isUploading = false

        let parts = AttachmentMarkdownBuilder.build(images: [image], files: [], currentDestination: .vault)

        XCTAssertTrue(parts.isEmpty)
    }

    func testMixedDestinationsOnlyEmitTheOneMatchingCurrentDestination() {
        var vaultImage = PendingImage(image: image())
        vaultImage.uploadedURL = "Attachments/vault.jpg"
        vaultImage.vaultPath = "Attachments/vault.jpg"
        vaultImage.isUploading = false

        var serverImage = PendingImage(image: image())
        serverImage.uploadedURL = "https://example.com/file/server"
        serverImage.isUploading = false

        let parts = AttachmentMarkdownBuilder.build(
            images: [vaultImage, serverImage],
            files: [],
            currentDestination: .vault
        )

        XCTAssertEqual(parts, ["![[vault.jpg]]"])
    }

    func testStillUploadingImageIsSkippedRegardlessOfDestination() {
        let image = PendingImage(image: image()) // uploadedURL nil, isUploading true

        let parts = AttachmentMarkdownBuilder.build(images: [image], files: [], currentDestination: .vault)

        XCTAssertTrue(parts.isEmpty)
    }

    func testFilesAreAlwaysIncludedWhenUploaded() {
        var file = PendingFile(filename: "notes.pdf")
        file.uploadedURL = "https://example.com/file/notes.pdf"
        file.isUploading = false

        let parts = AttachmentMarkdownBuilder.build(images: [], files: [file], currentDestination: .memos)

        XCTAssertEqual(parts, ["[notes.pdf](https://example.com/file/notes.pdf)"])
    }
}
