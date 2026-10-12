import Foundation
import FoundationModels

/// The Mac assistant: a thin shell around the platform-neutral
/// `AtlasModelHost`. It supplies the Mac's native read tools, the session and
/// cursor context, the saved MCP connections and the runtime choice.
@MainActor
enum AtlasAssistant {
    private static var lastPrewarm = Date.distantPast

    /// Mac identity, native tool guidance and untrusted session context.
    struct MacContext: AtlasContextProvider {
        let context: VoiceSessionContext
        let cursorContext: String?

        var assistantIdentity: String { "You are Omni, a helpful assistant on this Mac." }
        var nativeToolGuidance: String {
            "Use getMacContext for live Mac facts and inspectLocalFiles for files or images. Use these before claiming you cannot inspect the Mac. Mac facts do not establish a remote connection's account, permissions or service data; retrieve those from the selected remote service. Local paths are absolute or ~; home is \(NSHomeDirectory()). "
        }
        func untrustedContextJSON() throws -> String {
            let values = ["codingAgentSessions": context.modelContext(maximumSessions: 3), "cursor": String((cursorContext ?? "Unavailable").prefix(4500))]
            return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        }
    }

    static func environment(context: VoiceSessionContext = VoiceSessionContext(sessions: [], focusedID: nil), cursorContext: String? = nil,
                            question: String = "") -> AtlasHostEnvironment {
        let mac = MacContextTool(cursorContext: cursorContext, question: question)
        let files = LocalFilesTool(question: question)
        var result = AtlasHostEnvironment(context: MacContext(context: context, cursorContext: cursorContext), tools: [
            AtlasHostTool<MacContextTool.Arguments>(name: mac.name, description: mac.description, call: { try await mac.call(arguments: $0) }),
            AtlasHostTool<LocalFilesTool.Arguments>(name: files.name, description: files.description, call: { try await files.call(arguments: $0) })
        ], telemetry: [
            "sdk.version": AtlasRunnerSelection.sdkVersion,
            "runtime": AtlasRunnerSelection.useGoHelper ? "go-helper" : "native"
        ], authorize: MCPAuthorization.configure)
        if AtlasMetalAgent.enabled {
            result.promptByteBudget = { try AtlasMetalAgent.promptBudget(instructions: $0, tools: $1) }
            result.respondStreaming = { try await AtlasMetalAgent.shared.respond(instructions: $0, prompt: $1, tools: $2, onPartial: $3) }
            result.respond = { try await AtlasMetalAgent.shared.respond(instructions: $0, prompt: $1, tools: $2) }
            if !AtlasRunnerSelection.useGoHelper {
                result.respondConversation = { try await AtlasMetalAgent.shared.respondConversation(instructions: $0, messagesJSON: $1, tools: $2, onPartial: $3) }
            }
        }
        return result
    }

    /// Load the on-device model with the stable first-step instructions, and
    /// open remote MCP sessions, while the user is still speaking.
    static func prewarm() {
        guard AgentPreferences.shared.enabled else { return }
        guard case .available = SystemLanguageModel.default.availability,
              Date().timeIntervalSince(lastPrewarm) > 20 else { return }
        lastPrewarm = .now
        let servers = LocalMCPConfiguration.shared.enabledServers
        AtlasModelHost.prewarm(environment: environment(), servers: servers)
        AtlasRunnerSelection.prewarmConnections(servers)
    }

    static func instructions(_ frame: AtlasFrame, allowMCP: Bool, allowMCPResources: Bool) -> String {
        AtlasModelHost.instructions(frame, allowMCP: allowMCP, allowMCPResources: allowMCPResources, environment: environment())
    }

    static func answer(_ question: String, context: VoiceSessionContext, cursorContext: String?,
                       executable: URL? = AtlasBridge.helperURL, identity: AtlasBuildIdentity? = AtlasBridge.buildIdentity,
                       runner: (any AtlasRunner<AtlasFrame>)? = nil,
                       servers: [MCPServerConfiguration]? = nil,
                       conversation: [AssistantConversationTurn] = [],
                       memory: AssistantMemory? = nil, resumeTask: UUID? = nil,
                       onProgress: (@MainActor (String) -> Void)? = nil,
                       onTrace: (@MainActor (Int, String?) -> Void)? = nil,
                       onProposal: (@MainActor (AtlasToolCall) -> Void)? = nil,
                       onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
        guard AgentPreferences.shared.enabled else { throw AgentDisabledError() }
        return try await AtlasModelHost.answer(question, environment: environment(context: context, cursorContext: cursorContext, question: question),
            runner: runner ?? AtlasRunnerSelection.runner(executable: executable, identity: identity),
            servers: servers ?? LocalMCPConfiguration.shared.enabledServers, conversation: conversation,
            memory: memory, resumeTask: resumeTask, onProgress: onProgress, onTrace: onTrace, onProposal: onProposal, onPartial: onPartial)
    }
}

private struct AgentDisabledError: LocalizedError {
    var errorDescription: String? { "Enable the agent in Settings → Assistant & Mac." }
}
