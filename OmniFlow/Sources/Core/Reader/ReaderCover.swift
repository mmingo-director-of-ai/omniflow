import CoreGraphics
import Foundation
import ImageIO

/// Book covers, decoded straight to the size shown: ImageIO reads the file
/// once and downsamples without decoding the full-size image.
enum ReaderCover {
    /// A thumbnail whose longest side is `pixels`, or nil if unreadable.
    static func thumbnail(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Initials for a generated cover: the first letters of the first two significant words.
    static func initials(_ title: String) -> String {
        let skip: Set<String> = ["the", "a", "an", "of", "and", "for", "to", "in", "on", "with"]
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let significant = words.filter { !skip.contains($0.lowercased()) }
        return String((significant.isEmpty ? words : significant).prefix(2).compactMap(\.first)).uppercased()
    }
}
