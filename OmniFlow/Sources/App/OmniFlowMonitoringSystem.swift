// Copyright (c) 2026 Quandry Labs (MIT).
import AppKit
import Darwin

enum OmniFlowSoftwareUpdateStatus: Equatable, Sendable {
    case checking
    case upToDate
    case available(count: Int, title: String?)
    case unavailable
}

struct OmniFlowSystemSnapshot: Equatable, Sendable {
    let hostname: String
    let operatingSystem: String
    let uptime: TimeInterval
    let cpuUsage: Double?
    let perCoreCPUUsage: [Double]
    let memoryUsed: UInt64?
    let physicalMemory: UInt64
    let diskFree: UInt64?
    let diskTotal: UInt64?
    let networkReceiveRate: Double?
    let networkTransmitRate: Double?
    let lanIPv4: String?
    let lanIPv6: String?
    let vpnInterface: String?
    let vpnAddress: String?
    let publicIPv4: String?
    let publicIPv6: String?
    let loggedInUser: String
    let username: String
    let operatingSystemBuild: String?
    let hardwareTelemetry: OmniFlowHardwareTelemetrySample
    var networkReceiveHistory: [Double]
    var networkTransmitHistory: [Double]
    /// Filled by the coordinator, newest last.
    var cpuHistory: [Double] = []
    /// What Finder reports as available: free space plus purgeable space macOS can reclaim.
    var diskAvailable: UInt64? = nil
    var softwareUpdateStatus: OmniFlowSoftwareUpdateStatus

    static let placeholder = OmniFlowSystemSnapshot(
        hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        operatingSystem: "macOS",
        uptime: ProcessInfo.processInfo.systemUptime,
        cpuUsage: nil,
        perCoreCPUUsage: [],
        memoryUsed: nil,
        physicalMemory: ProcessInfo.processInfo.physicalMemory,
        diskFree: nil,
        diskTotal: nil,
        networkReceiveRate: nil,
        networkTransmitRate: nil,
        lanIPv4: nil,
        lanIPv6: nil,
        vpnInterface: nil,
        vpnAddress: nil,
        publicIPv4: nil,
        publicIPv6: nil,
        loggedInUser: NSFullUserName(),
        username: NSUserName(),
        operatingSystemBuild: nil,
        hardwareTelemetry: .placeholder,
        networkReceiveHistory: [],
        networkTransmitHistory: [],
        softwareUpdateStatus: .unavailable
    )
}

actor OmniFlowSystemSampler {
    private struct CPUCounters: Sendable {
        let busy: UInt64
        let total: UInt64
    }

    private struct NetworkCounters: Sendable {
        let received: UInt64
        let transmitted: UInt64
    }

    private struct InterfaceAddress: Sendable {
        let name: String
        let family: Int32
        let address: String
    }

    private struct LocalNetworkState: Sendable {
        let lanIPv4: String?
        let lanIPv6: String?
        let vpnInterface: String?
        let vpnAddress: String?
    }

    private var previousCPU: [CPUCounters]?
    private var previousNetwork: (counters: NetworkCounters, date: Date)?
    private var lastPublicAddressAttempt: Date?
    private var previousVPNInterface: String?
    private var cachedPublicIPv4: String?
    private var cachedPublicIPv6: String?
    private let hardwareTelemetryReader = OmniFlowHardwareTelemetryReader()

    /// Values that do not change while the app runs. `Host.localizedName` can
    /// block on name resolution, so it is read once instead of every tick.
    private struct Identity: Sendable {
        let hostname: String
        let operatingSystem: String
        let operatingSystemBuild: String?
        let loggedInUser: String
        let username: String
    }
    private var cachedIdentity: Identity?

    private func identity() -> Identity {
        if let cachedIdentity { return cachedIdentity }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let identity = Identity(
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            operatingSystem: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemBuild: systemBuildVersion(),
            loggedInUser: NSFullUserName(),
            username: NSUserName())
        cachedIdentity = identity
        return identity
    }

    func sample(includeNetworkDetails: Bool, allowPublicAddressLookup: Bool = false) async -> OmniFlowSystemSnapshot {
        let identity = identity()
        let memory = memoryUsage()
        let disk = diskUsage()
        let network = includeNetworkDetails ? networkRates() : (received: nil as Double?, transmitted: nil as Double?)
        if !includeNetworkDetails { previousNetwork = nil }
        let processor = processorUsage()
        let hardwareTelemetry = hardwareTelemetryReader.sample()
        let localNetwork = includeNetworkDetails ? localNetworkState() : nil

        if localNetwork?.vpnInterface != previousVPNInterface {
            previousVPNInterface = localNetwork?.vpnInterface
            lastPublicAddressAttempt = nil
        }
        let publicAddresses = includeNetworkDetails && allowPublicAddressLookup && !Task.isCancelled
            ? await publicAddresses()
            : (ipv4: nil, ipv6: nil)

        return OmniFlowSystemSnapshot(
            hostname: identity.hostname,
            operatingSystem: identity.operatingSystem,
            uptime: ProcessInfo.processInfo.systemUptime,
            cpuUsage: processor.overall,
            perCoreCPUUsage: processor.perCore,
            memoryUsed: memory.used,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            diskFree: disk.free,
            diskTotal: disk.total,
            networkReceiveRate: network.received,
            networkTransmitRate: network.transmitted,
            lanIPv4: localNetwork?.lanIPv4,
            lanIPv6: localNetwork?.lanIPv6,
            vpnInterface: localNetwork?.vpnInterface,
            vpnAddress: localNetwork?.vpnAddress,
            publicIPv4: publicAddresses.ipv4,
            publicIPv6: publicAddresses.ipv6,
            loggedInUser: identity.loggedInUser,
            username: identity.username,
            operatingSystemBuild: identity.operatingSystemBuild,
            hardwareTelemetry: hardwareTelemetry,
            networkReceiveHistory: [],
            networkTransmitHistory: [],
            diskAvailable: diskAvailable(),
            softwareUpdateStatus: .unavailable
        )
    }

    private func processorUsage() -> (overall: Double?, perCore: [Double]) {
        guard let current = cpuCounters() else { return (nil, []) }
        defer { previousCPU = current }

        guard let previous = previousCPU, previous.count == current.count else {
            return (nil, [])
        }

        var totalBusyDelta: UInt64 = 0
        var totalDelta: UInt64 = 0
        let perCore = zip(current, previous).map { pair -> Double in
            let (currentCore, previousCore) = pair
            guard currentCore.total >= previousCore.total,
                  currentCore.busy >= previousCore.busy,
                  currentCore.total > previousCore.total
            else {
                return 0
            }
            let busyDelta = currentCore.busy - previousCore.busy
            let coreTotalDelta = currentCore.total - previousCore.total
            totalBusyDelta += busyDelta
            totalDelta += coreTotalDelta
            return min(1, max(0, Double(busyDelta) / Double(coreTotalDelta)))
        }

        guard totalDelta > 0 else { return (nil, perCore) }
        return (
            min(1, max(0, Double(totalBusyDelta) / Double(totalDelta))),
            perCore
        )
    }

    private func cpuCounters() -> [CPUCounters]? {
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: processorInfo),
                vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        return (0..<Int(processorCount)).map { processorIndex in
            let offset = processorIndex * Int(CPU_STATE_MAX)
            let user = UInt64(processorInfo[offset + Int(CPU_STATE_USER)])
            let system = UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(processorInfo[offset + Int(CPU_STATE_NICE)])
            let idle = UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)])
            return CPUCounters(
                busy: user + system + nice,
                total: user + system + nice + idle
            )
        }
    }

    private func systemBuildVersion() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func memoryUsage() -> (used: UInt64?, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (nil, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let freePages = UInt64(statistics.free_count) + UInt64(statistics.speculative_count)
        let free = freePages * UInt64(pageSize)
        return (total > free ? total - free : 0, total)
    }

    private func diskUsage() -> (free: UInt64?, total: UInt64?) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
            return (nil, nil)
        }
        let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value
        let total = (attributes[.systemSize] as? NSNumber)?.uint64Value
        return (free, total)
    }

    private func diskAvailable() -> UInt64? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 >= 0 ? UInt64($0) : nil }
    }

    private func networkRates() -> (received: Double?, transmitted: Double?) {
        guard let current = networkCounters() else { return (nil, nil) }
        let now = Date()
        defer { previousNetwork = (current, now) }

        guard let previous = previousNetwork else { return (nil, nil) }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0,
              current.received >= previous.counters.received,
              current.transmitted >= previous.counters.transmitted
        else {
            return (nil, nil)
        }

        return (
            Double(current.received - previous.counters.received) / elapsed,
            Double(current.transmitted - previous.counters.transmitted) / elapsed
        )
    }

    private func networkCounters() -> NetworkCounters? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var transmitted: UInt64 = 0
        var interface: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = interface {
            defer { interface = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let data = current.pointee.ifa_data
            else {
                continue
            }

            let interfaceData = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(interfaceData.ifi_ibytes)
            transmitted += UInt64(interfaceData.ifi_obytes)
        }

        return NetworkCounters(received: received, transmitted: transmitted)
    }

    private func localNetworkState() -> LocalNetworkState {
        let addresses = interfaceAddresses()
        let lanAddresses = addresses
            .filter { !isVPNInterface($0.name) && isLANInterface($0.name) }
            .sorted { interfacePriority($0.name) < interfacePriority($1.name) }
        let vpnAddresses = addresses.filter { isVPNInterface($0.name) }
        let vpnInterface = vpnAddresses.first?.name
        let vpnAddress = vpnInterface.flatMap { name in
            vpnAddresses
                .filter { $0.name == name }
                .map(\.address)
                .uniqued()
                .prefix(2)
                .joined(separator: " · ")
        }

        return LocalNetworkState(
            lanIPv4: lanAddresses.first { $0.family == AF_INET }?.address,
            lanIPv6: lanAddresses.first { $0.family == AF_INET6 }?.address,
            vpnInterface: vpnInterface,
            vpnAddress: vpnAddress?.isEmpty == false ? vpnAddress : nil
        )
    }

    private func interfaceAddresses() -> [InterfaceAddress] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return [] }
        defer { freeifaddrs(addresses) }

        var result: [InterfaceAddress] = []
        var interface: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = interface {
            defer { interface = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0,
                  flags & Int32(IFF_LOOPBACK) == 0,
                  let socketAddress = current.pointee.ifa_addr
            else {
                continue
            }

            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = host.withUnsafeMutableBufferPointer { buffer in
                getnameinfo(
                    socketAddress,
                    socklen_t(socketAddress.pointee.sa_len),
                    buffer.baseAddress,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard status == 0 else { continue }

            let hostBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let address = String(decoding: hostBytes, as: UTF8.self)
                .components(separatedBy: "%").first ?? ""
            guard !address.isEmpty,
                  !address.hasPrefix("169.254."),
                  !address.lowercased().hasPrefix("fe80:")
            else {
                continue
            }

            result.append(
                InterfaceAddress(
                    name: String(cString: current.pointee.ifa_name),
                    family: family,
                    address: address
                )
            )
        }
        return result
    }

    private func isVPNInterface(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
    }

    private func isLANInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    private func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        return 2
    }

    private func publicAddresses() async -> (ipv4: String?, ipv6: String?) {
        if let lastPublicAddressAttempt,
           Date().timeIntervalSince(lastPublicAddressAttempt) < 300
        {
            return (cachedPublicIPv4, cachedPublicIPv6)
        }

        lastPublicAddressAttempt = Date()
        async let ipv4 = fetchPublicAddress(
            from: URL(string: "https://api.ipify.org")!,
            family: AF_INET
        )
        async let ipv6 = fetchPublicAddress(
            from: URL(string: "https://api6.ipify.org")!,
            family: AF_INET6
        )
        let refreshed = await (ipv4, ipv6)
        cachedPublicIPv4 = refreshed.0 ?? cachedPublicIPv4
        cachedPublicIPv6 = refreshed.1 ?? cachedPublicIPv6
        return (cachedPublicIPv4, cachedPublicIPv6)
    }

    private func fetchPublicAddress(from url: URL, family: Int32) async -> String? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6

        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              data.count <= 128,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              isIPAddress(value, family: family)
        else {
            return nil
        }
        return value
    }

    private func isIPAddress(_ value: String, family: Int32) -> Bool {
        var storage = in6_addr()
        return value.withCString { inet_pton(family, $0, &storage) == 1 }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

