import Foundation
import Testing
import Synchronization
@testable import OmniFlowApp

/// A private (0700) scratch directory removed when the test ends.
final class ScratchDirectory {
    let path: String
    init() {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("atlas-rt-XXXXXXXX").utf8CString)
        path = template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)!) }
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }
}

func object(_ text: String) -> [String: AtlasJSON] { try! AtlasJSON.parse(text).dictionary! }

func decoded(_ text: String) -> [String: AtlasJSON] { (try? AtlasJSON.parse(text))?.dictionary ?? [:] }

/// A session whose host answers analysis frames with `respond`.
func memoryFixture(store directory: String? = nil, _ respond: @escaping @Sendable (AtlasRuntimeAnalysisRequest) -> AtlasRuntimeFrame) throws -> AtlasRuntimeSession {
    let session = AtlasRuntimeSession(host: { frame in
        guard frame.type == "analysis", let request = frame.analysis else { throw AtlasRuntimeError("unexpected_callback") }
        var reply = respond(request)
        reply.type = "reply"; reply.version = 4; reply.requestID = frame.requestID; reply.id = frame.id
        return reply
    })
    session.requestID = "memory-test"
    session.store = try AtlasPayloadStore(directory: directory)
    session.memory = AtlasTaskJournal(session: session)
    session.mcp = try AtlasMCPHost(configs: [], store: session.store, pool: MCPConnectionPool(), launcher: nil)
    return session
}

func reply(_ result: AtlasRuntimeAnalysisReply) -> AtlasRuntimeFrame {
    var frame = AtlasRuntimeFrame(type: "reply"); frame.analysisResult = result; return frame
}

final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Drives an in-process run like the Go tests drive the helper's pipes: read
/// the next outbound frame (model/analysis/tool callback, event, or done) and
/// write a reply to the pending callback.
final class FrameClient: @unchecked Sendable {
    private let stream: AsyncStream<AtlasRuntimeFrame>
    private var iterator: AsyncStream<AtlasRuntimeFrame>.Iterator
    final class Pending: Sendable { let slot = Mutex<CheckedContinuation<AtlasRuntimeFrame, any Error>?>(nil) }
    private let pending = Pending()
    private(set) var task: Task<AtlasRuntimeFrame, any Error>!

    init(_ start: AtlasRuntimeFrame, pool: MCPConnectionPool = MCPConnectionPool(), launcher: AtlasStdioLauncher? = nil, discoveryTimeout: Double = 20) {
        let (stream, continuation) = AsyncStream<AtlasRuntimeFrame>.makeStream()
        self.stream = stream
        iterator = stream.makeAsyncIterator()
        let pending = pending
        var start = start
        start.version = 4
        start.requestID = start.requestID ?? "test-request"
        let frozen = start
        task = Task {
            let session = AtlasRuntimeSession(host: { frame in
                try await withCheckedThrowingContinuation { (callback: CheckedContinuation<AtlasRuntimeFrame, any Error>) in
                    pending.slot.withLock { $0 = callback }
                    continuation.yield(frame)
                }
            }, events: { continuation.yield($0) }, pool: pool, launcher: launcher)
            session.discoveryTimeout = discoveryTimeout
            do {
                let done = try await withTaskCancellationHandler {
                    try await session.serve(frozen)
                } onCancel: {
                    pending.slot.withLock { $0?.resume(throwing: CancellationError()); $0 = nil }
                }
                continuation.yield(done)
                continuation.finish()
                return done
            } catch {
                continuation.finish()
                throw error
            }
        }
    }

    func read() async -> AtlasRuntimeFrame? { await iterator.next() }

    func write(_ frame: AtlasRuntimeFrame, id: String?) {
        var reply = frame
        reply.type = "reply"; reply.version = 4; reply.requestID = "test-request"; reply.id = id
        pending.slot.withLock { $0?.resume(returning: reply); $0 = nil }
    }

    func reply(to frame: AtlasRuntimeFrame, content: String? = nil, toolCalls: [AtlasRuntimeToolCall]? = nil) {
        var reply = AtlasRuntimeFrame(type: "reply")
        reply.content = content
        reply.toolCalls = toolCalls
        write(reply, id: frame.id)
    }

    var result: Result<AtlasRuntimeFrame, any Error> { get async { await task.result } }
}

func startFrame(_ prompt: String = "What is the local fixture label?", servers: [AtlasMCPServerConfig] = [], question: String? = nil,
                discoveryQuery: String? = nil) -> AtlasRuntimeFrame {
    var frame = AtlasRuntimeFrame(type: "start")
    frame.prompt = prompt
    frame.tools = [AtlasRuntimeToolDefinition(name: "getMacContext", inputSchemaJSON: #"{"type":"object"}"#),
                   AtlasRuntimeToolDefinition(name: "inspectLocalFiles", inputSchemaJSON: #"{"type":"object"}"#)]
    frame.servers = servers
    frame.question = question
    frame.discoveryQuery = discoveryQuery
    return frame
}

func call(_ name: String, _ arguments: String) -> [AtlasRuntimeToolCall] { [AtlasRuntimeToolCall(name: name, argumentsJSON: arguments)] }

func sha256Hex(_ text: String) -> String {
    var bytes = Array(text.utf8)
    return AtlasPayloadStore.digest(bytes.withUnsafeMutableBufferPointer { Array($0) })
}

/// The approval digest for a tool definition, computed as the Go helper did.
func approvalDigest(_ definitionJSON: String) -> String { sha256Hex(try! AtlasJSON.parse(definitionJSON).goText) }
