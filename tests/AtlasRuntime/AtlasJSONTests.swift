import Foundation
import Testing
import CryptoKit
@testable import OmniFlowApp

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

struct AtlasJSONTests {
    @Test func goMarshalOracleIsByteExact() throws {
        let lines = try String(contentsOf: Fixtures.directory.appendingPathComponent("go-json-oracle.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        var strings = 0, floats = 0
        for line in lines {
            let record = try AtlasJSON.parse(String(line))
            if let input = record["input"]?.stringValue, let output = record["output"]?.stringValue {
                let raw = Data(base64Encoded: input)!
                let expected = Data(base64Encoded: output)!
                let encoded = try AtlasJSON.parse(raw).goBytes
                #expect(Data(encoded) == expected, "\(String(decoding: expected, as: UTF8.self)) vs \(String(decoding: encoded, as: UTF8.self))")
                let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
                #expect(digest == record["sha256"]?.stringValue)
                strings += 1
            } else if let bits = record["float"]?.doubleValue, let output = record["output"]?.stringValue {
                // Bit patterns above 2^53 lose precision as JSON doubles; re-parse from the line text instead.
                let text = String(line)
                let start = text.range(of: "\"float\":")!.upperBound
                let end = text[start...].firstIndex(of: ",")!
                let value = Double(bitPattern: UInt64(text[start..<end])!)
                _ = bits
                #expect(AtlasJSON.number(value).goText == output, "\(value)")
                floats += 1
            }
        }
        #expect(strings == 8 && floats == 26)
    }
}
