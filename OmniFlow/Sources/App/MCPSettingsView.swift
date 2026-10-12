import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject private var configuration = LocalMCPConfiguration.shared
    @State private var draft = MCPServerConfiguration()
    @State private var argumentsJSON = "[]"
    @State private var catalog: MCPCatalog?
    @State private var selected = Set<String>()
    @State private var editing = false
    @State private var message = ""
    @State private var probe: Task<Void, Never>?
    @State private var probeID: UUID?
    @State private var authorization: Task<Void, Never>?
    @State private var authorizationID: UUID?
    @State private var signedIn = false

    private var busy: Bool { probe != nil || authorization != nil }

    var body: some View {
        GroupBox("MCP connections") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect local programs or remote HTTPS tools.")
                    .font(.system(size: 12))
                Text("Choose exactly which tools OmniFlow may use. Remote connections receive the arguments for selected tool calls; your conversation is not uploaded automatically.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(configuration.servers) { server in
                    HStack {
                        Toggle(isOn: Binding(get: { server.enabled }, set: { enabled in
                            var updated = server; updated.enabled = enabled
                            save(updated)
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Label(server.destination, systemImage: server.isRemote ? "network" : "terminal")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("\(server.allowedTools.count) tools").font(.caption).foregroundStyle(.secondary)
                        Button { edit(server) } label: { Image(systemName: "pencil") }
                            .help("Edit \(server.name)").accessibilityLabel("Edit \(server.name)")
                        Button(role: .destructive) {
                            do {
                                if server.useOAuth { try MCPOAuth.shared.disconnect(server: server) }
                                try configuration.remove(server.id)
                            } catch { message = error.localizedDescription }
                        } label: { Image(systemName: "trash") }
                        .help("Remove \(server.name)").accessibilityLabel("Remove \(server.name)")
                    }.disabled(busy)
                }
                if configuration.servers.isEmpty {
                    Text("No MCP servers connected.").font(.caption).foregroundStyle(.secondary)
                }
                if !editing {
                    Button("Add connection") { edit(MCPServerConfiguration()) }
                        .disabled(configuration.servers.count >= 8)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Server name", text: $draft.name)
                        Picker("Connection", selection: $draft.transport) {
                            Text("Local program").tag("stdio")
                            Text("Remote HTTPS").tag("http")
                        }.pickerStyle(.segmented)
                            .onChange(of: draft.transport) { invalidateCatalog(resetSignIn: true) }
                        if draft.isRemote {
                            TextField("HTTPS endpoint, e.g. https://example.com/mcp", text: $draft.url)
                                .onChange(of: draft.url) { invalidateCatalog(resetSignIn: true) }
                            Text("Tool discovery and approved calls contact this endpoint. Results are processed on this Mac using the on-device model.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Sign in with this server", isOn: $draft.useOAuth)
                                .onChange(of: draft.useOAuth) { invalidateCatalog() }
                            if draft.useOAuth {
                                HStack {
                                    Label(signedIn ? "Signed in" : "Not signed in", systemImage: signedIn ? "checkmark.circle" : "person.crop.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(signedIn ? "Reconnect" : "Sign in") { signIn() }
                                        .disabled(draft.name.isEmpty || !MCPServerConfiguration.isValidRemoteEndpoint(draft.url))
                                    if signedIn {
                                        Button("Disconnect") { disconnect() }
                                    }
                                    if authorization != nil { ProgressView().controlSize(.small) }
                                }
                                Text("Sign in through your browser. OmniFlow keeps its own credentials in Keychain, tied to this endpoint.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Use default browser") { signIn(presentation: .defaultBrowser) }
                                    .disabled(draft.name.isEmpty || !MCPServerConfiguration.isValidRemoteEndpoint(draft.url))
                                Text("If the sign-in window fails, close it and try a fresh sign-in in your default browser.")
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("OAuth options") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        TextField("OAuth client ID (if required)", text: $draft.oauthClientID)
                                            .onChange(of: draft.oauthClientID) { invalidateCatalog() }
                                        Text("Leave empty for servers that support automatic registration.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(.top, 4)
                                }
                            }
                        } else {
                            TextField("Executable path, e.g. /opt/homebrew/bin/node", text: $draft.command)
                                .onChange(of: draft.command) { invalidateCatalog() }
                            TextField("Arguments (JSON array)", text: $argumentsJSON, axis: .vertical)
                                .font(.system(.caption, design: .monospaced)).lineLimit(2...5)
                                .onChange(of: argumentsJSON) { invalidateCatalog() }
                            Text("Arguments are passed literally. This program's network access is blocked and writes are limited to a temporary folder; shell settings are not imported.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(busy)
                    HStack {
                        Button("Save connection") { saveConnection() }.disabled(busy)
                        Button(probe == nil ? "Discover tools" : "Discovering…") { discover() }
                            .disabled(busy || draft.name.isEmpty || (draft.isRemote ? draft.url.isEmpty : !draft.command.hasPrefix("/")) || (draft.useOAuth && !signedIn))
                        if probe != nil { ProgressView().controlSize(.small) }
                        Button(authorization == nil ? "Cancel" : "Cancel sign-in") {
                            if authorization != nil {
                                cancelAuthorization()
                                message = "Sign-in cancelled."
                            } else {
                                probe?.cancel(); probe = nil; probeID = nil; editing = false
                            }
                        }
                    }
                    if let catalog {
                        Text("Allow these tools").font(.system(size: 12, weight: .semibold))
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(catalog.tools) { tool in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Toggle(tool.name, isOn: Binding(get: { selected.contains(tool.name) }, set: { enabled in
                                            if enabled { selected.insert(tool.name) } else { selected.remove(tool.name) }
                                        })).disabled(!tool.supported)
                                        Text(tool.supported ? tool.description : "This tool uses schema features OmniFlow does not yet support.")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            }
                        }.frame(maxHeight: 230)
                        if catalog.hasResources {
                            Toggle("Allow reading this server's discovered resources", isOn: $draft.allowResources)
                        }
                        Text("A changed tool definition requires approval again. Server descriptions and results are treated as untrusted data.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Save and enable") {
                            draft.allowedTools = catalog.tools.filter { selected.contains($0.name) && $0.supported }
                                .map { MCPToolApproval(name: $0.name, digest: $0.digest) }
                            draft.enabled = true
                            if save(draft) { editing = false }
                        }.disabled(selected.isEmpty && !draft.allowResources)
                    }
                }
                if let error = configuration.error { Text(error).font(.caption).foregroundStyle(.red) }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Large results stay on this Mac for the current question. OmniFlow retrieves chunks as needed, then deletes the working files when the question finishes or is cancelled.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(6)
        }
        .onDisappear { probe?.cancel(); probe = nil; probeID = nil; cancelAuthorization() }
    }

    private func invalidateCatalog(resetSignIn: Bool = false) {
        catalog = nil; selected = []; draft.allowResources = false; draft.allowedTools = []; draft.headers = [:]; draft.authorizationError = nil
        if resetSignIn { draft.useOAuth = false }
        updateSignInStatus()
    }

    private func edit(_ server: MCPServerConfiguration) {
        draft = server
        argumentsJSON = String(decoding: (try? JSONEncoder().encode(server.arguments)) ?? Data("[]".utf8), as: UTF8.self)
        catalog = nil; selected = []; message = ""; editing = true
        updateSignInStatus()
    }

    private func updateSignInStatus() {
        signedIn = draft.isRemote && draft.useOAuth && MCPOAuth.shared.hasCredential(for: draft)
    }

    private func cancelAuthorization() {
        authorization?.cancel(); authorization = nil; authorizationID = nil
    }

    private func signIn(presentation: MCPOAuthPresentation = .authenticationSession) {
        do { try LocalMCPConfiguration.validate(draft) }
        catch { message = error.localizedDescription; return }
        let server = draft
        let id = UUID()
        authorizationID = id
        message = presentation == .defaultBrowser
            ? "Complete the fresh sign-in in your default browser. Keep OmniFlow open; you can cancel here."
            : "Complete sign-in in the authentication window."
        authorization = Task { @MainActor in
            defer { if authorizationID == id { authorization = nil; authorizationID = nil } }
            do {
                try await MCPOAuth.shared.authorize(server: server, presentation: presentation)
                try Task.checkCancellation()
                guard authorizationID == id else { return }
                invalidateCatalog()
                message = "Signed in. Discover tools to choose which ones OmniFlow can use."
            } catch is CancellationError { }
            catch {
                guard authorizationID == id else { return }
                updateSignInStatus()
                message = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    private func disconnect() {
        do {
            try MCPOAuth.shared.disconnect(server: draft)
            if VoiceAssistant.shared.phase == .thinking { VoiceAssistant.shared.cancel() }
            invalidateCatalog()
            message = "Signed out of this server."
        } catch { message = error.localizedDescription }
    }

    @discardableResult private func save(_ server: MCPServerConfiguration) -> Bool {
        do { try configuration.save(server); message = "Saved locally."; return true }
        catch { message = error.localizedDescription; return false }
    }

    private func prepareDraft() throws {
        if draft.isRemote {
            draft.command = ""
            draft.arguments = []
        } else {
            do { draft.arguments = try JSONDecoder().decode([String].self, from: Data(argumentsJSON.utf8)) }
            catch { throw MCPConfigurationError.invalidProgram }
            draft.url = ""
        }
        try LocalMCPConfiguration.validate(draft)
    }

    private func saveConnection() {
        do { try prepareDraft() }
        catch { message = error.localizedDescription; return }
        let previous = configuration.servers.first { $0.id == draft.id }
        let grantsUnchanged = previous.map {
            $0.transport == draft.transport && $0.url == draft.url && $0.command == draft.command
                && $0.arguments == draft.arguments && $0.useOAuth == draft.useOAuth
                && $0.oauthClientID == draft.oauthClientID && $0.allowedTools == draft.allowedTools
                && $0.allowResources == draft.allowResources
        } ?? false
        draft.enabled = grantsUnchanged && previous?.enabled == true
        if save(draft) {
            message = draft.useOAuth && !signedIn
                ? "Connection saved. Sign in, then discover tools to choose what OmniFlow can use."
                : "Connection saved. Discover tools to choose what OmniFlow can use."
        }
    }

    private func discover() {
        do { try prepareDraft() }
        catch { message = error.localizedDescription; return }
        var server = draft; server.enabled = true
        message = server.isRemote ? "Connecting to \(server.destination)…" : "Starting the local server in a restricted work folder…"
        let id = UUID()
        probeID = id
        probe = Task { @MainActor in
            defer { if probeID == id { probe = nil; probeID = nil } }
            do {
                let found = try await AtlasRunnerSelection.catalog(server: server)
                try Task.checkCancellation()
                guard probeID == id else { return }
                catalog = found
                selected = Set(found.tools.filter { tool in
                    tool.supported && draft.allowedTools.contains { $0.name == tool.name && $0.digest == tool.digest }
                }.map(\.name))
                message = "Found \(found.tools.count) tools. Select the ones to allow."
            } catch is CancellationError { }
            catch AtlasBridgeError.mcpAuthentication {
                guard probeID == id else { return }
                if draft.isRemote { draft.useOAuth = true; updateSignInStatus() }
                message = "This server requires authentication. Choose Sign in or Reconnect, then discover its tools."
            }
            catch {
                guard probeID == id else { return }
                message = "Discovery failed: \(error.localizedDescription)"
            }
        }
    }
}
