import XCTest
import CoreGraphics
@testable import Quoote

final class ThumbnailDownsamplerTests: XCTestCase {

    func testTheLongestEdgeIsCappedAndTheAspectRatioKept() throws {
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: TestImages.png(width: 600, height: 300)))
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 96)
    }

    func testTheCapIsAMaximumNotATarget() throws {
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: TestImages.png(width: 40, height: 20)))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 192)
    }

    func testAnExifRotatedPhotoComesOutUpright() throws {
        // Stored 400x200 but tagged "rotate 90°": it is a portrait picture.
        let data = TestImages.jpeg(width: 400, height: 200, orientation: 6)
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: data))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 192)
    }

    func testATransparentPictureIsFlattenedOntoWhite() throws {
        let data = TestImages.png(width: 200, height: 200, transparent: true)
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: data))
        let corner = TestImages.pixel(of: image, x: 0, y: 0)
        XCTAssertEqual([corner.r, corner.g, corner.b, corner.a], [255, 255, 255, 255])
        let middle = TestImages.pixel(of: image, x: image.width / 2, y: image.height / 2)
        XCTAssertGreaterThan(middle.r, middle.g, "the painted part must survive")
    }

    func testBytesThatAreNotAnImageGiveNil() {
        XCTAssertNil(ThumbnailDownsampler.downsample(data: Data("not an image".utf8)))
        XCTAssertNil(ThumbnailDownsampler.downsample(data: Data()))
    }

    func testAFileOnDiskIsDownsampledWithoutReadingItAllIn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try TestImages.png(width: 800, height: 400).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(url: url))
        XCTAssertEqual(image.width, 192)
        XCTAssertNil(ThumbnailDownsampler.downsample(url: url.appendingPathExtension("missing")))
    }

    func testJPEGDataRoundTripsBackToTheSameSize() throws {
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: TestImages.png(width: 600, height: 300)))
        let jpeg = try XCTUnwrap(ThumbnailDownsampler.jpegData(from: image))
        let again = try XCTUnwrap(ThumbnailDownsampler.downsample(data: jpeg))
        XCTAssertEqual(again.width, image.width)
        XCTAssertEqual(again.height, image.height)
    }
}
