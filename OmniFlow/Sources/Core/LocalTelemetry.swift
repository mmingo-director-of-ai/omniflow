import Foundation
import Darwin

/// OTLP JSON file export: separate JSONL files for traces, metrics and logs.
/// Numeric enums, hexadecimal IDs and decimal-string 64-bit integers follow the OTLP spec.
/// No endpoint/exporter transport exists. No transcript, file path or email content is recorded.
actor LocalTelemetry {
    static let shared = LocalTelemetry()
    private let root: URL
    init(root: URL = NotchLeeStorage.root.appendingPathComponent("Telemetry")) { self.root = root }
    private var lastCleanup = Date.distantPast
    private var previousCPU: (time: TimeInterval, cpu: Double)?

    func sampleProcess() {
        guard UserDefaults.standard.object(forKey: "localTelemetryEnabled") as? Bool ?? true else { return }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS { gauge("process.memory.usage", value: Double(info.resident_size), unit: "By") }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let now = ProcessInfo.processInfo.systemUptime
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            if let previousCPU, now > previousCPU.time {
                gauge("process.cpu.utilization", value: max(0, (cpu - previousCPU.cpu) / (now - previousCPU.time) / Double(ProcessInfo.processInfo.processorCount)), unit: "1")
            }
            previousCPU = (now, cpu)
        }
    }

    static func nanoseconds(_ date: Date) -> String { String(UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000)) }
    static func identifier() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func tracePayload(name: String, start: Date, end: Date, success: Bool, attributes: [String: String]) -> [String: Any] {
        let span: [String: Any] = [
            "traceId": identifier(), "spanId": String(identifier().prefix(16)),
            "name": name, "kind": 1, "startTimeUnixNano": nanoseconds(start), "endTimeUnixNano": nanoseconds(end),
            "attributes": attributes.sorted { $0.key < $1.key }.map { ["key": $0.key, "value": ["stringValue": $0.value]] },
            "status": ["code": success ? 1 : 2]
        ]
        return ["resourceSpans": [["resource": resource, "scopeSpans": [["scope": scope, "spans": [span]]]]]]
    }

    private static var resource: [String: Any] {
        ["attributes": [["key": "service.name", "value": ["stringValue": "notchlee"]],
                         ["key": "service.version", "value": ["stringValue": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"]]]]
    }
    private static var scope: [String: Any] { ["name": "notchlee.local", "version": "1.0"] }

    func span(_ name: String, start: Date, success: Bool = true, attributes: [String: String] = [:]) {
        write(Self.tracePayload(name: name, start: start, end: .now, success: success, attributes: attributes), signal: "traces")
    }

    func event(_ name: String, success: Bool = true) {
        let log: [String: Any] = ["timeUnixNano": Self.nanoseconds(.now), "severityNumber": success ? 9 : 17,
                                  "severityText": success ? "INFO" : "ERROR", "body": ["stringValue": name]]
        write(["resourceLogs": [["resource": Self.resource, "scopeLogs": [["scope": Self.scope, "logRecords": [log]]]]]], signal: "logs")
    }

    func gauge(_ name: String, value: Double, unit: String) {
        guard value.isFinite else { return }
        let metric: [String: Any] = ["name": name, "unit": unit,
                                     "gauge": ["dataPoints": [["timeUnixNano": Self.nanoseconds(.now), "asDouble": value]]]]
        write(["resourceMetrics": [["resource": Self.resource, "scopeMetrics": [["scope": Self.scope, "metrics": [metric]]]]]], signal: "metrics")
    }

    private func write(_ payload: [String: Any], signal: String) {
        guard UserDefaults.standard.object(forKey: "localTelemetryEnabled") as? Bool ?? true else { return }
        do {
            try NotchLeeStorage.prepare(root)
            let day = String(Date().ISO8601Format().prefix(10))
            let file = root.appendingPathComponent("\(day)-\(signal).jsonl")
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size < 2_000_000 { try NotchLeeStorage.append(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), to: file) }
            if Date().timeIntervalSince(lastCleanup) > 3600 {
                lastCleanup = .now
                for old in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) where old.pathExtension == "jsonl" {
                    if let modified = try old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       Date().timeIntervalSince(modified) > 14 * 86400 { try FileManager.default.removeItem(at: old) }
                }
            }
        } catch { /* Telemetry never blocks the assistant. */ }
    }
}
