import Foundation
import Darwin

enum MacDiagnostics {
    struct ProcessSample: Codable, Sendable {
        let pid: Int
        let name: String
        let cpuPercent: Double
        let memoryMB: Int
    }

    static func parseProcesses(_ output: String) -> [ProcessSample] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1]),
                  let residentKB = Int(fields[2]), cpu.isFinite, residentKB >= 0 else { return nil }
            return ProcessSample(pid: pid, name: String((String(fields[3]) as NSString).lastPathComponent.prefix(100)),
                                 cpuPercent: cpu, memoryMB: residentKB / 1024)
        }
    }

    static func processes(spoken: Bool = false) async -> String {
        // Fixed executable/arguments only. Never include argv or environment variables in context.
        let output = await Task.detached(priority: .utility) {
            let child = Process()
            let pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/ps")
            child.arguments = ["-A", "-o", "pid=,pcpu=,rss=,comm="]
            child.standardOutput = pipe
            child.standardError = FileHandle.nullDevice
            child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            do { try child.run() } catch { return "" }
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: deadline)
            var data = Data()
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                if data.count < 2_000_000 { data.append(chunk) }
            }
            child.waitUntilExit()
            deadline.cancel()
            return child.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
        }.value
        let samples = parseProcesses(output)
        guard !samples.isEmpty else { return "Process resource usage is unavailable." }
        let cpu = samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8)
        let memory = samples.sorted { $0.memoryMB > $1.memoryMB }.prefix(8)
        if spoken {
            let cpuText = cpu.prefix(3).map { "\($0.name) at \(String(format: "%.1f", $0.cpuPercent)) percent" }.joined(separator: ", ")
            let memoryText = memory.prefix(3).map { "\($0.name) at \($0.memoryMB) MB" }.joined(separator: ", ")
            return "The top CPU users right now are \(cpuText). The largest memory users are \(memoryText). CPU percentages count 100 percent per core; memory is resident RAM."
        }
        return "Live process sample. CPU is a recent percentage (100% = one core); RAM is resident memory, in MB. Data only:\n"
            + LocalHostData.json(["highestCPU": Array(cpu), "highestMemory": Array(memory)])
    }

    static func memory() -> String {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "Memory usage is unavailable." }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        func size(_ pages: UInt32) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(pages) * Int64(pageSize), countStyle: .memory)
        }
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        return "Memory: \(size(stats.active_count)) active, \(size(stats.wire_count)) wired, \(size(stats.compressor_page_count)) compressed, \(size(stats.inactive_count)) inactive, \(size(stats.free_count)) free. Load averages (1, 5, 15 min): \(load.map { String(format: "%.2f", $0) }.joined(separator: ", ")). Free memory alone does not indicate memory pressure."
    }

    static func network() -> String {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return "Network interface details are unavailable." }
        defer { freeifaddrs(first) }
        var rows: [String] = []
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let item = next {
            defer { next = item.pointee.ifa_next }
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0, let address = item.pointee.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            rows.append("\(String(cString: item.pointee.ifa_name)): \(String(cString: name))")
        }
        return "Local network interfaces (no internet connection or external lookup was made):\n" + rows.prefix(16).joined(separator: "\n")
    }
}

enum LocalHostData {
    static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "Unavailable" }
        return String(decoding: data, as: UTF8.self)
    }
}
