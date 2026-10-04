import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns image bytes into a small bitmap without ever holding the full-size one: ImageIO decodes straight to the
/// thumbnail size. Everything it returns is opaque, so a transparent PNG (a macOS screenshot with its shadow)
/// doesn't turn black when it is cached as a JPEG.
enum ThumbnailDownsampler {

    /// The longest edge, in pixels, of every thumbnail the app keeps: a 56 pt tile at 3x.
    static let maxPixel = 192

    static func downsample(url: URL, maxPixel: Int = ThumbnailDownsampler.maxPixel) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    static func downsample(data: Data, maxPixel: Int = ThumbnailDownsampler.maxPixel) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    /// JPEG bytes for the disk cache.
    static func jpegData(from image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour the EXIF orientation: a phone photo's pixels are stored sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return opaque(image)
    }

    /// The image over white, unless it has no alpha already.
    private static func opaque(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}
