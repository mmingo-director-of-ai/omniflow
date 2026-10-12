// Native Atlas runtime: gzip framing compatible with Go's compress/gzip.
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// Apple's Compression framework provides raw DEFLATE (COMPRESSION_ZLIB); the
// RFC 1952 header, CRC-32 and ISIZE trailer are handled here. Inflation is
// streamed with a hard output bound so decompression bombs cannot exhaust memory.
import Compression
import Foundation

enum AtlasGzip {
    struct Failure: Error { let code: String }

    static func compress(_ data: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]
        output.append(contentsOf: try stream(data, operation: COMPRESSION_STREAM_ENCODE, limit: Int.max).0)
        appendLittleEndian(crc32(data), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &output)
        return output
    }

    /// Decompresses a single-member gzip stream (what Go's gzip.Writer and
    /// Python's gzip.compress produce). Returns at most `limit` + 1 bytes so
    /// callers can detect an exceeded budget exactly as `io.LimitReader(r,
    /// limit+1)` does; CRC-32 and ISIZE are verified for a complete stream.
    /// Compression's decoder reads ahead, so the trailer is taken from the end
    /// of the input; concatenated members fail the checksum and are rejected.
    static func decompress(_ data: [UInt8], limit: Int) throws -> [UInt8] {
        let body = try headerEnd(data, from: 0)
        guard data.count >= body + 8 else { throw Failure(code: "invalid_gzip_trailer") }
        let (inflated, _, finished) = try stream(Array(data[body..<(data.count - 8)]), operation: COMPRESSION_STREAM_DECODE, limit: limit + 1)
        if inflated.count > limit { return inflated }
        guard finished else { throw Failure(code: "invalid_gzip_data") }
        let crc = readLittleEndian(data, data.count - 8), size = readLittleEndian(data, data.count - 4)
        guard crc == crc32(inflated), size == UInt32(truncatingIfNeeded: inflated.count) else { throw Failure(code: "invalid_gzip_checksum") }
        return inflated
    }

    /// Validates the RFC 1952 header and returns the offset of the DEFLATE body.
    static func headerEnd(_ data: [UInt8], from start: Int) throws -> Int {
        guard data.count >= start + 10, data[start] == 0x1F, data[start + 1] == 0x8B, data[start + 2] == 8 else {
            throw Failure(code: "invalid_gzip_header")
        }
        let flags = data[start + 3]
        guard flags & 0xE0 == 0 else { throw Failure(code: "invalid_gzip_header") }
        var index = start + 10
        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= data.count else { throw Failure(code: "invalid_gzip_header") }
            index += 2 + Int(data[index]) | Int(data[index + 1]) << 8
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 { // FNAME, FCOMMENT
            while index < data.count && data[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 } // FHCRC
        guard index <= data.count else { throw Failure(code: "invalid_gzip_header") }
        return index
    }

    /// Runs a raw DEFLATE stream. Returns output (bounded by `limit`), consumed
    /// input bytes, and whether the stream reached its end marker.
    private static func stream(_ input: [UInt8], operation: compression_stream_operation, limit: Int) throws -> ([UInt8], Int, Bool) {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure(code: "compression_unavailable")
        }
        defer { compression_stream_destroy(streamPointer) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output: [UInt8] = []
        return try input.withUnsafeBufferPointer { source in
            streamPointer.pointee.src_ptr = source.baseAddress ?? UnsafePointer(buffer)
            streamPointer.pointee.src_size = source.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = chunk
                let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                let status = compression_stream_process(streamPointer, flags)
                let produced = chunk - streamPointer.pointee.dst_size
                output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
                let consumed = source.count - streamPointer.pointee.src_size
                if output.count > limit { return (Array(output.prefix(limit)), consumed, false) }
                switch status {
                case COMPRESSION_STATUS_END: return (output, consumed, true)
                case COMPRESSION_STATUS_OK:
                    // Decoding with no input left and no progress means truncation.
                    if operation == COMPRESSION_STREAM_DECODE && produced == 0 && streamPointer.pointee.src_size == 0 {
                        return (output, consumed, false)
                    }
                default: throw Failure(code: "invalid_gzip_data")
                }
            }
        }
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func appendLittleEndian(_ value: UInt32, to output: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    private static func readLittleEndian(_ data: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }
}
