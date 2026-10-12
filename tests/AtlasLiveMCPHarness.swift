import Foundation
import FoundationModels

/// Live MCP read scenarios through `AtlasAssistant.answer`, on the native
/// runtime or the Go helper, with question latency per round. Uses the MCP
/// servers and sign-ins already saved by the app; it never adds credentials.
/// Only each case's listed read actions may be dispatched: any other proposed
/// tool, action or native read stops the process before the call runs.
///
/// Usage (inside a signed copy of the app bundle, see scripts/run-atlas-live-mcp.sh):
///   <cases.json> <native|go> <rounds> <output folder> [case id ...]
struct LiveReadCase: Decodable {
    let id: String
    let question: String
    let tool: String
    let actions: [String]
}

@main enum AtlasLiveMCPHarness {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 5, ["native", "go"].contains(args[2]), let rounds = Int(args[3]), rounds > 0 else {
            report("usage: <cases.json> <native|go> <rounds> <output folder> [case id ...]"); exit(64)
        }
        let runtime = args[2]
        UserDefaults.standard.setVolatileDomain(["localTelemetryEnabled": false, "ambientEnabled": false,
                                                 AtlasRunnerSelection.goHelperDefaultsKey: runtime == "go"],
                                                forName: UserDefaults.argumentDomain)
        AtlasRunnerSelection.launch()
        do {
            var cases = try JSONDecoder().decode([LiveReadCase].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            if args.count > 5 { cases = cases.filter { args[5...].contains($0.id) } }
            let folder = URL(fileURLWithPath: args[4], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let servers = LocalMCPConfiguration.shared.enabledServers
            guard !servers.isEmpty, case .available = SystemLanguageModel.default.availability else { throw HarnessError.unavailable }
            let saved = LocalMCPConfiguration.shared.servers
            // Bearer tokens, to prove none reaches a proposal or an answer.
            var tokens: [String] = []
            for server in servers where server.isRemote && server.useOAuth {
                tokens.append(String(try await MCPOAuth.shared.authorizationHeader(for: server).dropFirst(7)))
            }
            var results: [[String: Any]] = []
            for test in cases {
                for round in 1...rounds {
                    results.append(try await run(test, round: round, runtime: runtime, servers: servers, tokens: tokens, folder: folder))
                    let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: folder.appendingPathComponent("results-\(runtime).json"))
                }
            }
            guard saved == LocalMCPConfiguration.shared.servers else { throw HarnessError.stateChanged }
            AtlasRunnerSelection.shutdown()
            try await Task.sleep(for: .milliseconds(300))
            exit(results.allSatisfy { $0["readPathPassed"] as? Bool == true } ? 0 : 2)
        } catch {
            report("FAILED \(String(reflecting: type(of: error))) \(error)")
            exit(1)
        }
    }

    @MainActor static func run(_ test: LiveReadCase, round: Int, runtime: String, servers: [MCPServerConfiguration],
                               tokens: [String], folder: URL) async throws -> [String: Any] {
        let memory = AssistantMemory(root: folder.appendingPathComponent("memory-\(runtime)-\(test.id)-\(round)"), defaults: nil)
        var calls: [String] = []
        var errors: [String] = []
        var firstModelFrame: TimeInterval?
        let started = Date()
        report("START \(runtime) \(test.id) round \(round)")
        let answer = try await AtlasAssistant.answer(test.question, context: VoiceSessionContext(sessions: [], focusedID: nil), cursorContext: nil,
            servers: servers, memory: memory,
            onTrace: { step, error in
                if firstModelFrame == nil { firstModelFrame = Date().timeIntervalSince(started) }
                if let error, !error.isEmpty { errors.append(error) }
                report("STEP \(step) error=\(error ?? "none")")
            }, onProposal: { call in
                guard !tokens.contains(where: { call.argumentsJSON.contains($0) }),
                      let fields = try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any] else {
                    report("BLOCKED credential or invalid proposal"); exit(8)
                }
                switch call.name {
                case "mcp":
                    let operation = fields["operation"] as? String ?? ""
                    let name = fields["name"] as? String ?? ""
                    report("PROPOSAL mcp \(operation) \(name)")
                    if operation == "call" {
                        guard name == test.tool, let raw = fields["argumentsJSON"] as? String,
                              let input = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                            report("BLOCKED unexpected live tool: \(name)"); exit(7)
                        }
                        let action = input["action"] as? String ?? ""
                        guard test.actions.contains(action) else { report("BLOCKED unexpected live action: \(action)"); exit(7) }
                        calls.append("\(name) \(action)")
                    } else if !["schema", "tools", "servers"].contains(operation) {
                        report("BLOCKED unplanned MCP operation \(operation)"); exit(7)
                    }
                case "payload", "memory", "recallSavedMemory":
                    report("PROPOSAL \(call.name) \(fields["operation"] as? String ?? "")")
                case "getMacContext" where ["system", "clock", "permissions"].contains(fields["topic"] as? String ?? ""):
                    report("LOCAL READ \(fields["topic"] as? String ?? "")")
                default:
                    report("BLOCKED unrelated native tool: \(call.name)"); exit(7)
                }
            })
        guard !tokens.contains(where: { answer.contains($0) }) else { throw HarnessError.credentialLeak }
        let seconds = Date().timeIntervalSince(started)
        let passed = !calls.isEmpty && errors.isEmpty
        report(String(format: "FINISH %@ %@ round %d: firstModelFrame=%.2fs total=%.2fs calls=%d errors=%d",
                      runtime, test.id, round, firstModelFrame ?? -1, seconds, calls.count, errors.count))
        return ["id": test.id, "runtime": runtime, "round": round, "calls": calls, "errors": errors, "answer": answer,
                "secondsToFirstModelFrame": firstModelFrame ?? -1, "secondsTotal": seconds, "readPathPassed": passed]
    }

    static func report(_ text: String) { try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8)) }
    enum HarnessError: Error { case unavailable, stateChanged, credentialLeak }
}
