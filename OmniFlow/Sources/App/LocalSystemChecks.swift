import Foundation
import Darwin
import IOKit.ps

struct LocalCheckResult: Equatable, Sendable {
    let title: String
    let detail: String
    let needsAttention: Bool
}

/// Fixed, read-only checks. No downloaded tools, database updates or outbound calls.
enum LocalSystemChecks {
    static func updates() -> LocalCheckResult {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return LocalCheckResult(title: "Update status unavailable", detail: "macOS has no readable local update result. Check Software Update in System Settings.", needsAttention: false)
        }
        let updates = plist["RecommendedUpdates"] as? [[String: Any]] ?? []
        let names = updates.prefix(12).map { item in
            [item["Display Name"] as? String ?? item["DisplayName"] as? String ?? "macOS update",
             item["Display Version"] as? String ?? item["DisplayVersion"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let date = (plist["LastSuccessfulDate"] as? Date).map { " Last macOS check: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? " The cache has no last-check date."
        return LocalCheckResult(title: updates.isEmpty ? "No updates in the local cache" : "\(updates.count) cached update\(updates.count == 1 ? "" : "s") available",
            detail: (names.isEmpty ? "This is not a fresh online check." : names.joined(separator: "\n")) + date, needsAttention: !updates.isEmpty)
    }

    static func security() async -> LocalCheckResult {
        let commands = [("Gatekeeper", "/usr/sbin/spctl", ["--status"]),
                        ("System Integrity Protection", "/usr/bin/csrutil", ["status"]),
                        ("FileVault", "/usr/bin/fdesetup", ["status"]),
                        ("Firewall", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])]
        var lines: [String] = []
        var attention = false
        for (label, path, arguments) in commands {
            let result = await run(path, arguments, timeout: 8)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(label): \(output.isEmpty ? "Unavailable" : output)")
            let lower = output.lowercased()
            attention = attention || lower.contains("disabled") || lower.contains("filevault is off") || lower.contains("state = 0")
        }
        return LocalCheckResult(title: attention ? "Review security protections" : "Local security check complete",
            detail: lines.joined(separator: "\n") + "\nThese are configuration checks, not a complete vulnerability assessment.", needsAttention: attention)
    }

    static var scannerPath: String? {
        ["/opt/homebrew/bin/trivy", "/usr/local/bin/trivy"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func scanFolder(_ url: URL) async -> String {
        guard let scannerPath else { return "No existing Trivy installation was found. No scanner or project was installed." }
        let result = await run(scannerPath, ["fs", "--config", "/dev/null", "--offline-scan", "--skip-db-update", "--skip-java-db-update", "--scanners", "vuln",
                                            "--disable-telemetry", "--skip-version-check", "--timeout", "90s", url.path], timeout: 100)
        return result.output.isEmpty ? "The offline scanner produced no result (exit \(result.code))." : String(result.output.prefix(24_000))
    }

    @MainActor static func purge() async -> String {
        #if APPSTORE
        return "Administrator maintenance is unavailable in this build."
        #else
        // Only this explicit UI action can invoke the fixed command. The model and
        // ambient rules cannot elevate privileges or supply shell arguments.
        let result = await run("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"], timeout: 120)
        return result.code == 0 ? "Filesystem caches cleared. Running apps still own their memory." : "Purge wasn't completed. \(result.output.prefix(500))"
        #endif
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> (code: Int32, output: String) {
        return await Task.detached(priority: .utility) {
            let child = Process(); let pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
            child.standardOutput = pipe; child.standardError = pipe; child.standardInput = FileHandle.nullDevice
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": NSHomeDirectory()]
            do { try child.run() } catch { return (-1, "Unavailable: \(error.localizedDescription)") }
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            var data = Data()
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                if data.count < 200_000 { data.append(chunk) }
            }
            child.waitUntilExit(); deadline.cancel()
            return (child.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

actor AmbientHostSampler {
    private var previousCPU: [UInt32]?
    struct Sample: Sendable { let cpu: Double?; let freeDiskPercent: Double?; let batteryPercent: Double? }
    func sample() -> Sample {
        var cpu = host_cpu_load_info(); var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &cpu) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        } }
        var percentage: Double?
        if result == KERN_SUCCESS {
            let ticks = withUnsafeBytes(of: cpu.cpu_ticks) { Array($0.bindMemory(to: UInt32.self)) }
            if let previousCPU {
                let delta = zip(ticks, previousCPU).map { Double($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { percentage = 100 * (total - delta[Int(CPU_STATE_IDLE)]) / total }
            }
            previousCPU = ticks
        }
        var disk: Double?
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = attrs[.systemSize] as? NSNumber, let free = attrs[.systemFreeSize] as? NSNumber, total.doubleValue > 0 {
            disk = 100 * free.doubleValue / total.doubleValue
        }
        var battery: Double?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      data[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                      let current = data[kIOPSCurrentCapacityKey] as? Int, let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                battery = 100 * Double(current) / Double(maximum)
            }
        }
        return Sample(cpu: percentage, freeDiskPercent: disk, batteryPercent: battery)
    }
}
