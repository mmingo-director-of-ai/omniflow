import Foundation
import Security
import Darwin

/// Launch-only broker in the existing Atlas executable. It owns the local
/// server sandbox and lifetime independently of remote HTTPS connections.
/// Every MCP server is sandboxed before receiving any requests or source data.
@MainActor
final class LocalMCPLauncher {
    static let shared = LocalMCPLauncher()
    private var process: Process?
    private var lifetime: FileHandle?
    private var directory: URL?
    private var address: MCPBrokerEndpoint?
    var endpoint: MCPBrokerEndpoint? { process?.isRunning == true ? address : nil }

    @discardableResult
    func start(executable: URL? = AtlasBridge.helperURL) -> Bool {
        #if APPSTORE
        return false
        #else
        guard process == nil, let executable else { return endpoint != nil }
        var secret = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nlm-" + UUID().uuidString.prefix(12), isDirectory: true)
        let endpoint = MCPBrokerEndpoint(socket: directory.appendingPathComponent("s").path,
            token: secret.map { String(format: "%02x", $0) }.joined())
        guard endpoint.socket.utf8.count <= 100 else { return false }
        let child = Process()
        let input = Pipe()
        child.executableURL = executable
        child.arguments = ["--mcp-broker"]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "GOTRACEBACK": "none"]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try child.run()
            try input.fileHandleForReading.close()
            var data = try JSONEncoder().encode(endpoint); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
            self.process = child; self.lifetime = input.fileHandleForWriting
            self.directory = directory; self.address = endpoint
            return true
        } catch {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            try? FileManager.default.removeItem(at: directory)
            return false
        }
        #endif
    }

    func stop() {
        try? lifetime?.close(); lifetime = nil
        address = nil
        // EOF is the normal shutdown path. The broker reaps every server group
        // before deleting its directory; a host crash also closes this pipe.
        if let process, process.isRunning { process.terminate() }
        process = nil
        directory = nil
    }
}
