// Native Atlas runtime: the original newline-delimited frame protocol
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// (port of main.go's readFrames/serve handshake). In-process callers use
// NativeAtlasRunner; this keeps the v4 wire contract available and testable.
import Foundation

public actor AtlasFrameServer {
    public static let maximumFrameBytes = 256 * 1024
    private var iterator: AsyncThrowingStream<[UInt8], any Error>.AsyncIterator
    private var buffer: [UInt8] = []
    private var ended = false
    private let output: @Sendable ([UInt8]) -> Void
    private let pool: MCPConnectionPool
    private let launcher: AtlasStdioLauncher?

    /// - Parameters:
    ///   - input: raw bytes from the host (any chunking).
    ///   - output: receives one encoded frame per call, newline-terminated.
    public init(input: AsyncThrowingStream<[UInt8], any Error>, output: @escaping @Sendable ([UInt8]) -> Void,
                pool: MCPConnectionPool = .shared, launcher: AtlasStdioLauncher? = AtlasRuntimeEnvironment.stdioLauncher) {
        iterator = input.makeAsyncIterator()
        self.output = output
        self.pool = pool
        self.launcher = launcher
    }

    nonisolated func write(_ frame: AtlasRuntimeFrame) {
        guard var data = try? JSONEncoder().encode(frame) else { return }
        data.append(0x0A)
        output(Array(data))
    }

    /// Next complete frame. Malformed JSON is `invalid_frame`; a line over the
    /// limit is `frame_limit`; end of input is `eof`.
    func receive() async throws -> AtlasRuntimeFrame {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                guard newline <= Self.maximumFrameBytes else { throw AtlasRuntimeError("frame_limit") }
                let line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let frame = try? JSONDecoder().decode(AtlasRuntimeFrame.self, from: Data(line)) else { throw AtlasRuntimeError("invalid_frame") }
                return frame
            }
            guard buffer.count <= Self.maximumFrameBytes else { throw AtlasRuntimeError("frame_limit") }
            guard !ended else {
                guard buffer.isEmpty else {
                    // A final unterminated line is still a frame (bufio.Scanner).
                    let line = buffer
                    buffer.removeAll()
                    guard let frame = try? JSONDecoder().decode(AtlasRuntimeFrame.self, from: Data(line)) else { throw AtlasRuntimeError("invalid_frame") }
                    return frame
                }
                throw AtlasRuntimeError("eof")
            }
            // The stream iterator shares its storage, so a local copy advances it.
            var local = iterator
            let chunk = try await local.next(isolation: self)
            iterator = local
            if let chunk { buffer += chunk } else { ended = true }
        }
    }

    /// Ready handshake, start validation, and one complete run. On failure the
    /// error is thrown; callers emit only a fixed code (see `errorFrame`).
    public func serve() async throws {
        var ready = AtlasRuntimeFrame(type: "ready")
        ready.version = AtlasRuntimeIdentity.protocolVersion
        ready.sdkVersion = AtlasRuntimeIdentity.version
        ready.revision = AtlasRuntimeIdentity.revision
        write(ready.normalized())
        let start = try await receive()
        let session = AtlasRuntimeSession(host: { [self] frame in
            write(frame)
            return try await receive()
        }, events: { [self] frame in write(frame) }, pool: pool, launcher: launcher)
        let done = try await session.serve(start)
        write(done)
    }

    /// Do not report errors that might embed a prompt, path, argument or result.
    public static func errorFrame(_ error: any Error) -> AtlasRuntimeFrame {
        var frame = AtlasRuntimeFrame(type: "error")
        frame.version = AtlasRuntimeIdentity.protocolVersion
        let code = (error as? AtlasRuntimeError)?.code ?? ""
        frame.error = atlasSafeMCPHTTPCodes.contains(code) ? code : "atlas_run_failed"
        return frame.normalized()
    }
}
