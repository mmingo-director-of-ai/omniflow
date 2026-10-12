import Foundation

/// An immutable surrounding draft plus the UTF-16 range owned by this dictation.
public struct OwnedText {
    public let original: String
    public let originalRange: NSRange
    public private(set) var inserted: String?
    public init(value: String, selection: NSRange) { original = value; originalRange = selection }
    public var originalSelection: String { (original as NSString).substring(with: originalRange) }
    public var replacementRange: NSRange { NSRange(location: originalRange.location, length: inserted.map { ($0 as NSString).length } ?? originalRange.length) }
    public var expectedValue: String { inserted.map { value(replacingWith: $0) } ?? original }
    public func value(replacingWith text: String) -> String { (original as NSString).replacingCharacters(in: originalRange, with: text) }
    public mutating func commit(_ text: String) { inserted = text }
}
