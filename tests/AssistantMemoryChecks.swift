import Foundation
import FoundationModels

@MainActor
enum AssistantMemoryChecks {
    static func run(executable: URL, identity: AtlasBuildIdentity, definitions: [AtlasToolDefinition],
                    server: MCPServerConfiguration, live: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-memory-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = AssistantMemory(root: root, defaults: nil)
        memory.project = "Juniper"
        let personal = SavedAssistantNote(scope: "", text: "I prefer temperatures in Celsius.")
        var project = SavedAssistantNote(scope: "Juniper", text: "The launch codename is amber-panda-82.")
        let other = SavedAssistantNote(scope: "Cobalt", text: "The launch codename is private-cobalt-93.")
        await memory.put(personal); await memory.put(project); await memory.put(other)
        precondition(memory.error == nil)
        let reopened = AssistantMemory(root: root, defaults: nil)
        reopened.project = "Juniper"
        await reopened.load()
        precondition(reopened.document.notes.count == 3, "Notes did not survive reopening")
        let recalled = try await reopened.recalled(query: "launch codename", scope: "Juniper", excluding: nil)
        precondition(recalled.first?.text.contains("amber-panda-82") == true)
        precondition(recalled.contains(where: { $0.text.contains("Celsius") }) && !recalled.contains(where: { $0.text.contains("private-cobalt-93") }),
                     "Personal/project recall crossed scope boundaries")
        project.text = "The launch codename is saffron-panda-84."
        await reopened.put(project)
        let changed = try await reopened.file.recall(query: "codename", scope: "Juniper")
        precondition(changed.contains(where: { $0.text.contains("saffron-panda-84") }) && !changed.contains(where: { $0.text.contains("amber-panda-82") }),
                     "An explicit correction left the obsolete note in recall")
        let noteRead = try await reopened.retrieve(.init(operation: .read, query: nil, id: "note/"+project.id.uuidString, offset: nil), scope: "Juniper", excluding: nil)
        precondition(noteRead.contains("saffron-panda-84"))
        do {
            _ = try await reopened.retrieve(.init(operation: .read, query: nil, id: "note/"+other.id.uuidString, offset: nil), scope: "Juniper", excluding: nil)
            preconditionFailure("Direct-id lookup bypassed project scope")
        } catch AssistantMemoryError.missing { }
        reopened.enabled = false
        let disabledRecall = try await reopened.recalled(query: "codename", scope: "Juniper", excluding: nil)
        let disabledTask = try await reopened.begin(question: "Do not retain", resume: nil)
        precondition(disabledRecall.isEmpty && disabledTask == nil)
        reopened.enabled = true
        let slice = try await AtlasContextWindow().prepare(messages: [.init(role: "user", content: "CURRENT_REQUEST")], archived: 0,
            capacity: 4096, fixedTokens: 800, responseTokens: 800, finalStep: false,
            savedMemory: recalled, count: { $0.utf8.count })
        precondition(slice.inputTokens + 1184 <= 4096 && slice.prompt.contains("CURRENT_REQUEST"))
        // Sensitive source text stays in the bounded data envelope, never in
        // system instructions or the current user request.
        precondition(slice.prompt.contains("untrusted data"))
        await reopened.forgetNote(personal.id)
        let afterDelete = try await reopened.file.recall(query: "Celsius", scope: "Juniper")
        precondition(!afterDelete.contains(where: { $0.id == "note/"+personal.id.uuidString }))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("memory.json").path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let longTask = try await reopened.begin(question: "Read a long saved entry", resume: nil)!
        await reopened.finish(longTask.task.id, answer: String(repeating: "紅熊猫 café ", count: 800))
        let longID = "task/" + longTask.task.id.uuidString
        let fullEntry = try await reopened.file.recall(query: "", scope: "Juniper").first { $0.id == longID }!.text
        var recovered = ""
        var readOffset = 0
        while true {
            let page = try await reopened.retrieve(.init(operation: .read, query: nil, id: longID, offset: readOffset), scope: "Juniper", excluding: nil)
            let object = try JSONSerialization.jsonObject(with: Data(page.utf8)) as! [String: Any]
            let entry = (object["records"] as! [[String: Any]])[0]
            recovered += entry["text"] as! String
            if object["hasMore"] as! Bool == false { break }
            let next = object["nextOffset"] as! Int
            precondition(next > readOffset); readOffset = next
        }
        precondition(recovered == fullEntry && readOffset > 0, "Paged saved-memory reads lost or split Unicode evidence")
        AtlasIntegrationTests.report("Persistent notes: reload, correction, project isolation, disabled recall, deletion and bounded context: passed")

        var fixture = server; fixture.arguments.append("small-analysis")
        let goal = "Summarize the staging and production decisions."
        let lease = try await reopened.begin(question: goal, resume: nil)!
        var extractionCount = 0
        var mcpCalls = 0
        var sourceID = ""
        let initial = AtlasBridge()
        do {
            _ = try await initial.run(prompt: goal, tools: definitions, servers: [fixture], question: goal,
                executable: executable, identity: identity, workspace: lease.directory,
                onModel: { frame in
                    if let request = frame.analysis {
                        extractionCount += 1
                        if extractionCount == 2 { throw CancellationError() }
                        let admitted = String(request.text!.prefix(4000))
                        let quote = "First decision: staging only."
                        precondition(admitted.contains(quote))
                        return AtlasFrame(type: "reply", analysisResult: .init(text: quote, quotes: [quote], consumedBytes: admitted.utf8.count, consumedRecords: 0))
                    }
                    if frame.step == 1 {
                        mcpCalls += 1
                        let args = MCPArguments(operation: .call, server: fixture.id, name: "read_archive", argumentsJSON: "{}", query: nil, offset: nil, cursor: nil)
                        return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: args.generatedContent.jsonString)])
                    }
                    let result = try AtlasIntegrationTests.toolObject(frame.messages!.last!.content)
                    let evidence = result["evidence"] as! [String: Any]
                    sourceID = (evidence["payload"] as! [String: Any])["id"] as! String
                    let args = AtlasMemoryArguments(operation: .analyze, id: sourceID, quote: nil, query: nil)
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: "memory", argumentsJSON: args.generatedContent.jsonString)])
                }, onTool: { _ in preconditionFailure("No native tools required") })
            preconditionFailure("Interrupted source processing unexpectedly completed")
        } catch is CancellationError { }
        // Wait for this specific child to release its OS workspace lock.
        for _ in 0..<100 {
            if let pid = initial.processID, kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
            else { break }
        }
        await reopened.finish(lease.task.id, answer: nil)
        precondition(reopened.error == nil)
        let interrupted = reopened.document.tasks.first { $0.id == lease.task.id }!
        precondition(interrupted.status == .interrupted && interrupted.progress!.processedBytes > 0 && interrupted.progress?.complete == false)
        let priorCursor = interrupted.progress!.processedBytes
        let partialRecall = try await reopened.file.recall(query: "staging production", scope: "Juniper")
        precondition(partialRecall.contains { $0.sourceTask == lease.task.id && $0.text.contains("incomplete") },
                     "Partial findings lost their coverage qualification when recalled")
        let fresh = AssistantMemory(root: root, defaults: nil); fresh.project = "Juniper"
        await fresh.load()
        let resumed = try await fresh.begin(question: goal, resume: lease.task.id)!
        do {
            _ = try await fresh.file.forgetTask(lease.task.id)
            preconditionFailure("A running workspace could be deleted")
        } catch AssistantMemoryError.busy { }
        var resumedPasses = 0
        let completed = try await AtlasBridge().run(prompt: goal, tools: definitions, question: goal,
            executable: executable, identity: identity, workspace: resumed.directory, resume: true,
            onModel: { frame in
                if let request = frame.analysis {
                    resumedPasses += 1
                    if request.phase == "extract" {
                        precondition(request.startByte >= priorCursor-320, "Resume replayed previously committed extraction")
                        let quote = "Final decision: production is NOT approved."
                        let found = request.text!.contains(quote)
                        return AtlasFrame(type: "reply", analysisResult: .init(text: found ? quote : "", quotes: found ? [quote] : [],
                            consumedBytes: request.text!.utf8.count, consumedRecords: 0))
                    }
                    return AtlasFrame(type: "reply", analysisResult: .init(text: request.records!.map(\.text).joined(separator: " "), quotes: [],
                        consumedBytes: 0, consumedRecords: request.records!.count))
                }
                precondition(frame.memory?.active?.complete == true && frame.previousError == nil)
                await fresh.update(lease.task.id, view: frame.memory)
                let result = frame.memory!.records.first { $0.id == frame.memory!.active!.result }!.text
                precondition(result.contains("staging") && result.contains("production is NOT approved"))
                return AtlasFrame(type: "reply", content: result)
            }, onTool: { _ in preconditionFailure("Resume must use cached source data, not external actions") })
        await fresh.finish(lease.task.id, answer: completed.text)
        precondition(mcpCalls == 1 && resumedPasses >= 2 && fresh.error == nil)
        precondition(FileManager.default.fileExists(atPath: lease.directory.appendingPathComponent(sourceID+".gz").path))
        let priorWork = try await fresh.file.recall(query: "staging production", scope: "Juniper")
        precondition(priorWork.contains { $0.sourceTask == lease.task.id && $0.text.contains("NOT approved") })
        AtlasIntegrationTests.report("Fresh helper resumes persisted source analysis after cancellation; prior findings and evidence survive; no MCP action replay: passed")

        if live {
            let again = AssistantMemory(root: root, defaults: nil); again.project = "Juniper"
            let answer = try await AtlasAssistant.answer("What is our launch codename? Use my saved project memory.",
                context: VoiceSessionContext(sessions: [], focusedID: nil), cursorContext: nil,
                executable: executable, identity: identity, servers: [], memory: again)
            precondition(answer.contains("saffron-panda-84") && !answer.contains("private-cobalt-93"), "Live model failed to recall the corrected, scoped note")
            AtlasIntegrationTests.report("Live Apple assistant recalls corrected project memory from a reopened store: passed")
        }
        await fresh.forgetTask(lease.task.id)
        precondition(!FileManager.default.fileExists(atPath: lease.directory.path), "Forgetting left raw task evidence behind")
        await fresh.clear()
        precondition(fresh.error == nil && fresh.document.notes.isEmpty && fresh.document.tasks.isEmpty)
        let damaged = root.appendingPathComponent("damaged")
        try NotchLeeStorage.prepare(damaged)
        let badFile = damaged.appendingPathComponent("memory.json")
        try Data("damaged original".utf8).write(to: badFile)
        let bad = AssistantMemoryFile(root: damaged)
        do { _ = try await bad.put(project); preconditionFailure("A corrupt memory store was overwritten") }
        catch AssistantMemoryError.damaged { }
        let preserved = try String(contentsOf: badFile, encoding: .utf8)
        precondition(preserved == "damaged original")
        let retained = AssistantMemoryFile(root: root.appendingPathComponent("retention"))
        _ = try await retained.put(project)
        var firstTask: UUID?
        for i in 0..<21 {
            let (task, _) = try await retained.begin(question: "Retention fixture \(i)", scope: "Juniper", resume: nil)
            if firstTask == nil { firstTask = task.task.id }
            _ = try await retained.finish(task.task.id, answer: "Fixture")
        }
        let limited = try await retained.load()
        precondition(limited.tasks.count == 20 && !limited.tasks.contains { $0.id == firstTask } && limited.notes.count == 1,
                     "Task retention discarded selected notes or exceeded its cap")
        AtlasIntegrationTests.report("Forgetting removes durable evidence; damaged storage fails without overwriting data: passed")
    }
}
