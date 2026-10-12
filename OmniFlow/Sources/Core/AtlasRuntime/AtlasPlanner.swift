// Native Atlas runtime: SDK task planning.
//
// Port of sdk/go/pkg/agent/planning.go from the canonical Atlas Go SDK (MIT,
// Copyright Quandry Labs) at revision 49104b74160ee24cc350eee461df6378e51cccd3.
// The NotchLee host never constructed a Planner; this is pure logic kept for
// SDK parity (keyword decomposition, verification, dependency scheduling).
import Foundation
import Synchronization

public enum AtlasPlanStatus: String, Sendable {
    case pending, inProgress = "in_progress", completed, failed, cancelled
}

public struct AtlasPlanStep: Sendable {
    public var id: String
    public var description: String
    public var tools: [String]
    public var dependencies: [String]
    public var status: AtlasPlanStatus = .pending
    public var result: String?
    public var error = ""
    public var startedAt: Date?
    public var completedAt: Date?
    public var retries = 0
}

public struct AtlasPlanMetadata: Sendable {
    public var totalSteps = 0
    public var completedSteps = 0
    public var failedSteps = 0
}

public struct AtlasExecutionPlan: Sendable {
    public var id: String
    public var goal: String
    public var steps: [AtlasPlanStep]
    public var status: AtlasPlanStatus = .pending
    public var createdAt = Date()
    public var startedAt: Date?
    public var completedAt: Date?
    public var metadata = AtlasPlanMetadata()
}

public struct AtlasPlanVerification: Sendable {
    public var valid: Bool
    public var errors: [String]
    public var warnings: [String]
    public var suggestions: [String]
}

public struct AtlasPlanProgress: Sendable {
    public var planID: String
    public var currentStep: Int
    public var totalSteps: Int
    public var completedSteps: Int
    public var failedSteps: Int
    public var percentComplete: Double
    public var estimatedTimeRemaining: TimeInterval?
}

public final class AtlasPlanner: Sendable {
    public struct Config: Sendable {
        public var maxSteps = 20
        public var maxDepth = 5
        public var verifyPlans = false
        public var trackProgress = false
        public var onProgress: (@Sendable (AtlasPlanProgress) -> Void)?
        public init() {}
    }

    let config: Config
    private let plans = Mutex<[String: AtlasExecutionPlan]>([:])

    public init(config: Config = Config()) {
        var config = config
        if config.maxSteps == 0 { config.maxSteps = 20 }
        if config.maxDepth == 0 { config.maxDepth = 5 }
        self.config = config
    }

    public func plan(goal: String, availableTools: [String]) throws -> AtlasExecutionPlan {
        let steps = decompose(goal, availableTools)
        var plan = AtlasExecutionPlan(id: Self.generateID("plan"), goal: goal, steps: steps)
        plan.metadata.totalSteps = steps.count
        if config.verifyPlans {
            let verification = verify(plan, availableTools: availableTools)
            if !verification.valid { throw AtlasRuntimeError("invalid plan: " + verification.errors.joined(separator: ", ")) }
        }
        plans.withLock { $0[plan.id] = plan }
        return plan
    }

    func decompose(_ goal: String, _ available: [String]) -> [AtlasPlanStep] {
        var steps: [AtlasPlanStep] = []
        let lower = AtlasText.goLower(goal)
        func step(_ description: String, _ tools: [String], _ dependencies: [String]) -> AtlasPlanStep {
            AtlasPlanStep(id: Self.generateID("step"), description: description, tools: tools, dependencies: dependencies)
        }
        if lower.contains("investigate") || lower.contains("analyze") {
            steps.append(step("Gather information about: \(goal)", filter(available, ["search", "get", "read", "list", "fetch"]), []))
            steps.append(step("Analyze gathered information", [], [steps[0].id]))
        }
        if lower.contains("create") || lower.contains("build") || lower.contains("implement") {
            steps.append(step("Plan implementation approach", [], []))
            // The SDK links this to steps[0], the first step of the whole plan.
            steps.append(step("Implement the solution", filter(available, ["create", "write", "update", "execute"]), [steps[0].id]))
        }
        if lower.contains("respond") || lower.contains("fix") || lower.contains("remediate") {
            steps.append(step("Assess the situation", filter(available, ["get", "read", "list"]), []))
            steps.append(step("Execute remediation actions", filter(available, ["update", "delete", "execute", "apply"]), [steps[0].id]))
            steps.append(step("Verify remediation success", filter(available, ["get", "read", "check", "verify"]), [steps[1].id]))
        }
        if steps.isEmpty { steps.append(step(goal, available, [])) }
        return steps
    }

    func filter(_ available: [String], _ keywords: [String]) -> [String] {
        guard !keywords.isEmpty else { return available }
        return available.filter { tool in keywords.contains { AtlasText.goLower(tool).contains($0) } }
    }

    public func verify(_ plan: AtlasExecutionPlan, availableTools: [String]) -> AtlasPlanVerification {
        var errors: [String] = [], warnings: [String] = [], suggestions: [String] = []
        if plan.steps.isEmpty { errors.append("Plan has no steps") }
        if plan.steps.count > config.maxSteps { warnings.append("Plan has \(plan.steps.count) steps, exceeds recommended maximum") }
        var visited: Set<String> = [], stack: Set<String> = []
        for step in plan.steps where hasCycle(step, plan.steps, &visited, &stack) {
            errors.append("Circular dependency detected involving step \(step.id)")
        }
        let ids = Set(plan.steps.map(\.id))
        for step in plan.steps {
            for dependency in step.dependencies where !ids.contains(dependency) {
                errors.append("Step \(step.id) depends on non-existent step \(dependency)")
            }
        }
        let toolSet = Set(availableTools)
        for step in plan.steps {
            for tool in step.tools where !toolSet.contains(tool) { warnings.append("Step \(step.id) requires unavailable tool: \(tool)") }
        }
        if plan.steps.count == 1 { suggestions.append("Consider breaking down the goal into smaller steps") }
        return AtlasPlanVerification(valid: errors.isEmpty, errors: errors, warnings: warnings, suggestions: suggestions)
    }

    private func hasCycle(_ step: AtlasPlanStep, _ all: [AtlasPlanStep], _ visited: inout Set<String>, _ stack: inout Set<String>) -> Bool {
        if stack.contains(step.id) { return true }
        if visited.contains(step.id) { return false }
        visited.insert(step.id); stack.insert(step.id)
        for dependency in step.dependencies {
            for candidate in all where candidate.id == dependency {
                if hasCycle(candidate, all, &visited, &stack) { return true }
            }
        }
        stack.remove(step.id)
        return false
    }

    private static func dependenciesComplete(_ step: AtlasPlanStep, in plan: AtlasExecutionPlan) -> Bool {
        step.dependencies.allSatisfy { id in plan.steps.contains { $0.id == id && $0.status == .completed } }
    }

    public func nextStep(_ plan: AtlasExecutionPlan) -> AtlasPlanStep? {
        plan.steps.first { $0.status == .pending && Self.dependenciesComplete($0, in: plan) }
    }

    public func executableSteps(_ plan: AtlasExecutionPlan) -> [AtlasPlanStep] {
        plan.steps.filter { $0.status == .pending && Self.dependenciesComplete($0, in: plan) }
    }

    public func startStep(_ plan: inout AtlasExecutionPlan, _ id: String) {
        if let index = plan.steps.firstIndex(where: { $0.id == id }) {
            let now = Date()
            plan.steps[index].status = .inProgress
            plan.steps[index].startedAt = now
            if plan.status == .pending { plan.status = .inProgress; plan.startedAt = now }
        }
        updateProgress(plan)
    }

    public func completeStep(_ plan: inout AtlasExecutionPlan, _ id: String, result: String?) {
        if let index = plan.steps.firstIndex(where: { $0.id == id }) {
            plan.steps[index].status = .completed
            plan.steps[index].completedAt = Date()
            plan.steps[index].result = result
            plan.metadata.completedSteps += 1
        }
        updateProgress(plan)
        checkCompletion(&plan)
    }

    public func failStep(_ plan: inout AtlasExecutionPlan, _ id: String, error: String) {
        if let index = plan.steps.firstIndex(where: { $0.id == id }) {
            plan.steps[index].status = .failed
            plan.steps[index].error = error
            plan.metadata.failedSteps += 1
        }
        updateProgress(plan)
    }

    @discardableResult
    public func retryStep(_ plan: inout AtlasExecutionPlan, _ id: String) -> Bool {
        guard let index = plan.steps.firstIndex(where: { $0.id == id && $0.status == .failed }) else { return false }
        plan.steps[index].status = .pending
        plan.steps[index].error = ""
        plan.steps[index].retries += 1
        plan.metadata.failedSteps -= 1
        return true
    }

    func updateProgress(_ plan: AtlasExecutionPlan) {
        guard config.trackProgress else { return }
        var progress = AtlasPlanProgress(planID: plan.id, currentStep: 0, totalSteps: plan.steps.count,
                                         completedSteps: plan.metadata.completedSteps, failedSteps: plan.metadata.failedSteps,
                                         percentComplete: Double(plan.metadata.completedSteps) / Double(plan.steps.count) * 100)
        if let index = plan.steps.firstIndex(where: { $0.status == .inProgress }) { progress.currentStep = index + 1 }
        if let started = plan.startedAt, plan.metadata.completedSteps > 0 {
            let average = Date().timeIntervalSince(started) / Double(plan.metadata.completedSteps)
            progress.estimatedTimeRemaining = average * Double(plan.steps.count - plan.metadata.completedSteps)
        }
        config.onProgress?(progress)
    }

    func checkCompletion(_ plan: inout AtlasExecutionPlan) {
        let finished = plan.steps.allSatisfy { $0.status == .completed || $0.status == .failed }
        guard finished else { return }
        plan.status = plan.steps.contains { $0.status == .failed } ? .failed : .completed
        plan.completedAt = Date()
    }

    public func plan(id: String) -> AtlasExecutionPlan? { plans.withLock { $0[id] } }

    @discardableResult
    public func cancelPlan(_ id: String) -> Bool {
        plans.withLock { plans in
            guard var plan = plans[id] else { return false }
            plan.status = .cancelled
            plan.completedAt = Date()
            for index in plan.steps.indices where plan.steps[index].status == .pending || plan.steps[index].status == .inProgress {
                plan.steps[index].status = .cancelled
            }
            plans[id] = plan
            return true
        }
    }

    static func generateID(_ prefix: String) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "\(prefix)_\(DispatchTime.now().uptimeNanoseconds)_" + String((0..<9).map { _ in letters.randomElement()! })
    }
}
