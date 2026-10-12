// The platform-neutral model/tool host driven by a fake runner, with no Mac
// tools — the configuration the iOS assistant uses.
import Foundation
import FoundationModels
import Testing
@testable import OmniFlowApp

@MainActor
struct AtlasModelHostTests {
    struct PhoneContext: AtlasContextProvider {
        var assistantIdentity: String { "You are Omni, a helpful assistant on this iPhone." }
        var nativeToolGuidance: String { "" }
        func untrustedContextJSON() throws -> String { #"{"surface":"phone-fixture"}"# }
    }

    /// Records what the host asks for and replays scripted callbacks.
    final class FakeRunner: AtlasRunner {
        typealias Frame = AtlasFrame
        var tools: [AtlasToolDefinition] = []
        var servers: [MCPServerConfiguration] = []
        var prompt = ""
        var toolError: (any Error)?
        var modelReply: AtlasFrame?
        let driveModel: Bool
        init(driveModel: Bool) { self.driveModel = driveModel }

        func run<Tool: Encodable, Server: Codable & Sendable>(
            prompt: String, tools: [Tool], servers: [Server], mode: String?, question: String?, discoveryQuery: String?,
            workspace: URL?, resume: Bool, timeout: Double, requireAuthentication: Bool,
            authorize: (@MainActor ([Server], Bool) async throws -> [Server])?,
            onModel: @escaping Handler, onTool: @escaping Handler) async throws -> AtlasRuntimeResult {
            self.prompt = prompt
            self.tools = tools as? [AtlasToolDefinition] ?? []
            self.servers = servers as? [MCPServerConfiguration] ?? []
            // A Mac tool name must not reach any tool on this host.
            var call = AtlasFrame(type: "tool")
            call.tool = "getMacContext"
            call.argumentsJSON = #"{"topic":"clock"}"#
            do { _ = try await onTool(call) } catch { toolError = error }
            if driveModel {
                var model = AtlasFrame(type: "model")
                model.step = 1
                model.messages = [AtlasMessage(role: "user", content: prompt)]
                model.memory = AtlasMemoryView(records: [], totalRecords: 0, analysisPasses: 0)
                model.payloadReady = false
                modelReply = try await onModel(model)
                return AtlasRuntimeResult(text: modelReply?.content ?? "", steps: 1, toolCount: 0)
            }
            return AtlasRuntimeResult(text: "Fixture answer.", steps: 1, toolCount: 0)
        }
    }

    var environment: AtlasHostEnvironment { AtlasHostEnvironment(context: PhoneContext(), tools: []) }

    @Test func runsWithoutMacToolsThroughAnyRunner() async throws {
        var server = MCPServerConfiguration()
        server.name = "Fixture"; server.transport = "http"; server.url = "https://example.invalid/mcp"; server.enabled = true
        let runner = FakeRunner(driveModel: false)
        let answer = try await AtlasModelHost.answer("What is on my calendar?", environment: environment, runner: runner, servers: [server])
        #expect(answer == "Fixture answer.")
        #expect(runner.tools.isEmpty, "the host advertised device tools it was not given")
        #expect(runner.servers.map(\.id) == ["s1"] && runner.servers.first?.name == "Fixture")
        #expect(runner.prompt.contains("What is on my calendar?") && runner.prompt.contains("phone-fixture"))
        #expect((runner.toolError as? AtlasBridgeError) == .invalidFrame)
    }

    @Test func instructionsCarryTheShellIdentityAndNoMacGuidance() {
        let text = AtlasModelHost.instructions(AtlasFrame(type: "model"), allowMCP: false, allowMCPResources: false, environment: environment)
        #expect(text.hasPrefix("You are Omni, a helpful assistant on this iPhone. Speak English"))
        #expect(!text.contains("getMacContext") && !text.contains("inspectLocalFiles"))
        // The Mac shell keeps its original wording.
        let mac = AtlasAssistant.instructions(AtlasFrame(type: "model"), allowMCP: false, allowMCPResources: false)
        #expect(mac.contains("You are Omni, a helpful assistant on this Mac. Speak English unless requested otherwise.")
                && mac.contains("Use getMacContext for live Mac facts") && mac.contains("home is \(NSHomeDirectory()). Never invent facts"))
    }

    /// With the on-device model available, the host answers a real model frame
    /// with no device tools at all.
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func answersAModelFrameWithTheOnDeviceModel() async throws {
        let runner = FakeRunner(driveModel: true)
        let answer = try await AtlasModelHost.answer("Reply with the single word ready.", environment: environment, runner: runner, servers: [])
        #expect(!answer.isEmpty && runner.modelReply?.toolCalls == nil)
    }

    /// The real runtime, not a fake: an iOS-shaped host with no device tools
    /// gets an answer end to end (the fake runner once hid a tool-count check).
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func answersThroughTheRealNativeRunnerWithNoTools() async throws {
        let runner = NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: AtlasBridgeError.remoteCode,
                                                   timedOut: AtlasBridgeError.timedOut)
        let answer = try await AtlasModelHost.answer("Reply with the single word ready.", environment: environment, runner: runner, servers: [])
        #expect(!answer.isEmpty)
    }
}
