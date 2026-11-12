// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

enum LaunchArtworkImages {
    static let maximumPhoto = 32 * 1024 * 1024
    static func dimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let width: Int, height: Int
        if data.count >= 48, data.prefix(8) == Data([0x41,0x41,0x50,0x4c,0x0d,0x0a,0x1a,0x0a]) {
            func word(_ offset: Int) -> Int { data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) } }
            guard data[12..<16] == Data("HEAD".utf8), word(16) == 1 else { throw invalid }
            width = word(40); height = word(44)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int else { throw invalid }
            width = w; height = h
        }
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw invalid }
        return (width, height)
    }
    static func render(_ photo: Data, width: Int, height: Int) throws -> Data {
        guard !photo.isEmpty, photo.count <= maximumPhoto, width > 0, height > 0, width <= 4096, height <= 4096,
              let source = CGImageSourceCreateWithData(photo as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceWidth > 0, sourceHeight > 0, sourceWidth <= 15000, sourceHeight <= 15000,
              sourceWidth * sourceHeight <= 120_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw invalid }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        guard let result = context.makeImage() else { throw invalid }
        return try png(result)
    }
    static func preview(_ data: Data) -> Data? {
        guard let size = try? dimensions(data) else { return nil }
        #if canImport(UIKit)
        if data.prefix(4) == Data([0x41,0x41,0x50,0x4c]), let image = UIImage(data: data)?.cgImage {
            return try? png(image)
        }
        #endif
        let ratio = min(1.0, 900.0 / Double(max(size.width, size.height)))
        return try? render(data, width: max(1, Int(Double(size.width) * ratio)), height: max(1, Int(Double(size.height) * ratio)))
    }
    static func export(_ data: Data) -> Data? {
        guard (try? dimensions(data)) != nil else { return nil }
        #if canImport(UIKit)
        if let image = UIImage(data: data)?.cgImage { return try? png(image) }
        #endif
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return try? png(image)
    }
    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw invalid }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw invalid }
        return data as Data
    }
    private static var invalid: CustomizationFailure { CustomizationFailure("This image could not be used. Choose another image.") }
}
