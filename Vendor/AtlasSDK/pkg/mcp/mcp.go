// Package mcp provides MCP (Model Context Protocol) client functionality.
//
// This file implements the multi-server Manager, a thin coordinator that holds
// one real *Bridge (see bridge.go) per connected MCP server and exposes a
// multi-server API. The full single-connection protocol client lives in
// bridge.go / types.go; the Manager delegates to those bridges.
package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

// TransportConfig holds MCP transport configuration used to connect a server.
type TransportConfig struct {
	Type    string            // "stdio", "http", "sse"
	Command string            // for stdio
	Args    []string          // for stdio
	Env     map[string]string // for stdio
	URL     string            // for http/sse
	Headers map[string]string // for http/sse
}

// managedServer wraps a Bridge with the resources needed to tear it down.
type managedServer struct {
	bridge    *Bridge
	transport Transport
	tools     []Tool
}

// Manager coordinates multiple MCP server connections. Each connected server is
// backed by a real *Bridge performing the full MCP protocol over a Transport.
type Manager struct {
	mu      sync.RWMutex
	servers map[string]*managedServer
}

// NewManager creates a new MCP manager.
func NewManager() *Manager {
	return &Manager{
		servers: make(map[string]*managedServer),
	}
}

// clientInfo is the implementation info advertised on initialize.
var clientInfo = Implementation{
	Name:    "atlas-sdk-go",
	Version: "1.0.0",
}

// Connect establishes a connection to an MCP server, performs the MCP
// initialize handshake, discovers its tools, and registers it under name.
// It returns the discovered tools.
func (m *Manager) Connect(ctx context.Context, name string, transport TransportConfig) ([]Tool, error) {
	// Reserve the name under the lock with a placeholder, then perform the
	// (potentially blocking) handshake WITHOUT holding the lock. This keeps a
	// slow/stalled server from freezing every other Manager method.
	m.mu.Lock()
	if _, exists := m.servers[name]; exists {
		m.mu.Unlock()
		return nil, fmt.Errorf("MCP server already connected: %s", name)
	}
	m.servers[name] = nil // placeholder reservation
	m.mu.Unlock()

	// On any failure, release the reservation so the name can be retried.
	cleanupReservation := func() {
		m.mu.Lock()
		if srv, ok := m.servers[name]; ok && srv == nil {
			delete(m.servers, name)
		}
		m.mu.Unlock()
	}

	tr, err := newTransport(ctx, transport)
	if err != nil {
		cleanupReservation()
		return nil, err
	}

	bridge := NewBridge()
	caps := ClientCapabilities{
		Roots:    &RootsCapability{},
		Sampling: map[string]interface{}{},
	}

	if _, err := bridge.Initialize(ctx, tr, clientInfo, caps); err != nil {
		// Initialize failed; make sure we don't leak the transport/process.
		_ = tr.Close()
		cleanupReservation()
		return nil, fmt.Errorf("failed to initialize MCP server %s: %w", name, err)
	}

	var tools []Tool
	if bridge.HasCapability("tools") {
		listResult, err := bridge.ListTools(ctx)
		if err != nil {
			// Connection is usable even if tool discovery failed; keep the
			// server registered so it can be retried/used.
			tools = nil
		} else {
			tools = listResult.Tools
		}
	}

	m.mu.Lock()
	// If the reservation was cleared out from under us (e.g. DisconnectAll ran
	// concurrently), tear this connection down instead of registering it.
	if srv, ok := m.servers[name]; !ok || srv != nil {
		m.mu.Unlock()
		_ = bridge.Close()
		_ = tr.Close()
		return nil, fmt.Errorf("MCP server connect for %s was superseded", name)
	}
	m.servers[name] = &managedServer{
		bridge:    bridge,
		transport: tr,
		tools:     tools,
	}
	m.mu.Unlock()

	return tools, nil
}

// ListServers returns the names of fully-connected MCP servers. Servers that
// are mid-handshake (reserved but not yet established) are omitted.
func (m *Manager) ListServers() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	servers := make([]string, 0, len(m.servers))
	for name, srv := range m.servers {
		if srv != nil {
			servers = append(servers, name)
		}
	}
	return servers
}

// GetTools returns the tools discovered for a specific MCP server.
func (m *Manager) GetTools(name string) ([]Tool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	srv, ok := m.servers[name]
	if !ok || srv == nil {
		return nil, fmt.Errorf("MCP server not found: %s", name)
	}
	return srv.tools, nil
}

// AllTools returns every tool across all connected servers, keyed by server name.
func (m *Manager) AllTools() map[string][]Tool {
	m.mu.RLock()
	defer m.mu.RUnlock()

	out := make(map[string][]Tool, len(m.servers))
	for name, srv := range m.servers {
		if srv != nil {
			out[name] = srv.tools
		}
	}
	return out
}

// CallTool invokes a tool on a specific MCP server and returns the result.
func (m *Manager) CallTool(ctx context.Context, serverName, toolName string, args map[string]interface{}) (*ToolResult, error) {
	m.mu.RLock()
	srv, ok := m.servers[serverName]
	m.mu.RUnlock()
	if !ok || srv == nil {
		return nil, fmt.Errorf("MCP server not found: %s", serverName)
	}
	return srv.bridge.CallTool(ctx, toolName, args)
}

// Disconnect closes the connection to a single MCP server and reaps its process.
func (m *Manager) Disconnect(ctx context.Context, name string) error {
	m.mu.Lock()
	srv, ok := m.servers[name]
	if ok {
		delete(m.servers, name)
	}
	m.mu.Unlock()

	if !ok || srv == nil {
		// Either not present, or a connect is still in flight (placeholder).
		// Removing the placeholder above signals that in-flight Connect to tear
		// itself down rather than register.
		return fmt.Errorf("MCP server not found: %s", name)
	}

	var firstErr error
	if err := srv.bridge.Close(); err != nil {
		firstErr = err
	}
	// Close the transport as well; for stdio this kills and reaps the child.
	if err := srv.transport.Close(); err != nil && firstErr == nil {
		firstErr = err
	}
	return firstErr
}

// DisconnectAll closes all MCP connections. Any in-flight connects (placeholder
// reservations) are cleared so they tear themselves down instead of registering.
func (m *Manager) DisconnectAll(ctx context.Context) error {
	m.mu.Lock()
	established := make([]string, 0, len(m.servers))
	for name, srv := range m.servers {
		if srv != nil {
			established = append(established, name)
		} else {
			// Clear the placeholder so the in-flight Connect aborts.
			delete(m.servers, name)
		}
	}
	m.mu.Unlock()

	var errs []error
	for _, name := range established {
		if err := m.Disconnect(ctx, name); err != nil {
			errs = append(errs, err)
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("errors disconnecting MCP servers: %v", errs)
	}
	return nil
}

// newTransport builds a concrete Transport for the given config.
func newTransport(ctx context.Context, cfg TransportConfig) (Transport, error) {
	switch cfg.Type {
	case "stdio":
		return newStdioTransport(ctx, cfg)
	case "http", "sse":
		return newHTTPTransport(cfg)
	default:
		return nil, fmt.Errorf("unsupported transport type: %s", cfg.Type)
	}
}

// ============================================================================
// stdio transport
// ============================================================================

// stdioTransport speaks newline-delimited JSON-RPC over a child process's
// stdin/stdout.
type stdioTransport struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
	reader *bufio.Reader

	mu      sync.Mutex
	closed  bool
	onError func(error)
	onClose func()
}

func newStdioTransport(ctx context.Context, cfg TransportConfig) (*stdioTransport, error) {
	if cfg.Command == "" {
		return nil, fmt.Errorf("stdio transport requires a command")
	}

	cmd := exec.CommandContext(ctx, cfg.Command, cfg.Args...)

	// M9(a): inherit the parent environment (PATH/HOME/...) so the MCP server
	// process can actually start, then layer the explicit transport env on top.
	cmd.Env = os.Environ()
	for k, v := range cfg.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open stdout pipe: %w", err)
	}
	cmd.Stderr = os.Stderr

	return &stdioTransport{
		cmd:    cmd,
		stdin:  stdin,
		stdout: stdout,
		reader: bufio.NewReader(stdout),
	}, nil
}

// Connect starts the child process.
func (t *stdioTransport) Connect() error {
	if err := t.cmd.Start(); err != nil {
		return fmt.Errorf("failed to start MCP server: %w", err)
	}
	return nil
}

// Close terminates the child process and reaps it to avoid zombies.
func (t *stdioTransport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	onClose := t.onClose
	t.mu.Unlock()

	// Closing stdin signals a graceful shutdown to well-behaved servers.
	if t.stdin != nil {
		_ = t.stdin.Close()
	}

	if t.cmd != nil && t.cmd.Process != nil {
		_ = t.cmd.Process.Kill()
		// M9(b): reap the child so it doesn't become a zombie.
		_ = t.cmd.Wait()
	}

	if t.stdout != nil {
		_ = t.stdout.Close()
	}

	if onClose != nil {
		onClose()
	}
	return nil
}

// Send writes a JSON-RPC request as a single newline-delimited line.
func (t *stdioTransport) Send(request *JSONRPCRequest) error {
	return t.writeJSON(request)
}

// SendNotification writes a JSON-RPC notification as a newline-delimited line.
func (t *stdioTransport) SendNotification(notification *JSONRPCNotification) error {
	return t.writeJSON(notification)
}

func (t *stdioTransport) writeJSON(v interface{}) error {
	data, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("failed to marshal message: %w", err)
	}
	data = append(data, '\n')

	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return fmt.Errorf("transport closed")
	}
	_, writeErr := t.stdin.Write(data)
	t.mu.Unlock()

	if writeErr != nil {
		t.reportError(writeErr)
		return fmt.Errorf("failed to write to MCP server: %w", writeErr)
	}
	return nil
}

// Receive reads the next JSON-RPC response line. Notifications (no id) are
// skipped so callers only observe responses to their requests.
func (t *stdioTransport) Receive() (*JSONRPCResponse, error) {
	for {
		line, err := t.reader.ReadBytes('\n')
		if err != nil {
			if err != io.EOF {
				t.reportError(err)
			}
			return nil, fmt.Errorf("failed to read from MCP server: %w", err)
		}

		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}

		var resp JSONRPCResponse
		if err := json.Unmarshal(line, &resp); err != nil {
			// Could be a notification or a non-response frame; skip it.
			continue
		}
		// Skip frames that carry no id (notifications) and no payload.
		if len(resp.ID) == 0 && resp.Result == nil && resp.Error == nil {
			continue
		}
		return &resp, nil
	}
}

// OnError registers a handler invoked on transport-level errors.
func (t *stdioTransport) OnError(handler func(error)) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.onError = handler
}

// OnClose registers a handler invoked when the transport closes.
func (t *stdioTransport) OnClose(handler func()) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.onClose = handler
}

func (t *stdioTransport) reportError(err error) {
	// reportError must be called WITHOUT t.mu held.
	t.mu.Lock()
	handler := t.onError
	t.mu.Unlock()
	if handler != nil {
		handler(err)
	}
}

// ============================================================================
// http transport
// ============================================================================

// httpTransport speaks JSON-RPC over HTTP POST (single request/response). It is
// a minimal implementation sufficient for request/response MCP servers.
type httpTransport struct {
	url     string
	headers map[string]string
	client  *http.Client

	mu      sync.Mutex
	pending *JSONRPCResponse
	hasResp bool
	closed  bool
	onError func(error)
	onClose func()
}

func newHTTPTransport(cfg TransportConfig) (*httpTransport, error) {
	if cfg.URL == "" {
		return nil, fmt.Errorf("http transport requires a URL")
	}
	return &httpTransport{
		url:     cfg.URL,
		headers: cfg.Headers,
		client:  &http.Client{Timeout: 60 * time.Second},
	}, nil
}

func (t *httpTransport) Connect() error { return nil }

func (t *httpTransport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	onClose := t.onClose
	t.mu.Unlock()

	if onClose != nil {
		onClose()
	}
	return nil
}

func (t *httpTransport) Send(request *JSONRPCRequest) error {
	resp, err := t.post(request)
	if err != nil {
		return err
	}
	t.mu.Lock()
	t.pending = resp
	t.hasResp = true
	t.mu.Unlock()
	return nil
}

// SendNotification posts a notification and discards any response body.
func (t *httpTransport) SendNotification(notification *JSONRPCNotification) error {
	_, err := t.post(notification)
	return err
}

func (t *httpTransport) post(v interface{}) (*JSONRPCResponse, error) {
	t.mu.Lock()
	closed := t.closed
	t.mu.Unlock()
	if closed {
		return nil, fmt.Errorf("transport closed")
	}

	body, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal message: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, t.url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("failed to build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	for k, v := range t.headers {
		req.Header.Set(k, v)
	}

	httpResp, err := t.client.Do(req)
	if err != nil {
		t.reportError(err)
		return nil, fmt.Errorf("http request failed: %w", err)
	}
	defer httpResp.Body.Close()

	data, err := io.ReadAll(httpResp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, nil
	}

	var resp JSONRPCResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}
	return &resp, nil
}

func (t *httpTransport) Receive() (*JSONRPCResponse, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.hasResp || t.pending == nil {
		return nil, fmt.Errorf("no pending response")
	}
	resp := t.pending
	t.pending = nil
	t.hasResp = false
	return resp, nil
}

func (t *httpTransport) OnError(handler func(error)) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.onError = handler
}

func (t *httpTransport) OnClose(handler func()) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.onClose = handler
}

func (t *httpTransport) reportError(err error) {
	t.mu.Lock()
	handler := t.onError
	t.mu.Unlock()
	if handler != nil {
		handler(err)
	}
}
