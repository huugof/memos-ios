import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Real image bytes for tests, made with CoreGraphics and ImageIO only.
enum TestImages {

    /// A solid-colour bitmap. With `transparent`, the colour is half-transparent over a fully clear border.
    static func bitmap(width: Int, height: Int, transparent: Bool = false) -> CGImage {
        let info = transparent ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue
        )!
        if !transparent {
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            // Only the middle is painted; the corners stay fully transparent.
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
        return context.makeImage()!
    }

    static func png(width: Int, height: Int, transparent: Bool = false) -> Data {
        encode(bitmap(width: width, height: height, transparent: transparent), as: .png)
    }

    /// A JPEG, optionally tagged with an EXIF orientation (6 = the camera was held upright, pixels stored sideways).
    static func jpeg(width: Int, height: Int, orientation: Int? = nil) -> Data {
        encode(bitmap(width: width, height: height), as: .jpeg, orientation: orientation)
    }

    private static func encode(_ image: CGImage, as type: UTType, orientation: Int? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The RGBA of one pixel, `(0, 0)` being the top-left.
    static func pixel(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Shift the image so the wanted pixel lands on the one-pixel canvas.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
