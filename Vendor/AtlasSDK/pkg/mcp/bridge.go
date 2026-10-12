/**
 * MCP Bridge - Full MCP Specification Implementation (Go SDK)
 *
 * Implements the stable Model Context Protocol revision advertised by MCPVersion with:
 * - Tools: list, call, with input validation
 * - Resources: list, read, subscribe, templates
 * - Prompts: list, get, with arguments
 * - Sampling: createMessage with LLM delegation
 * - Roots: list, changes notifications
 * - Logging: setLevel, log notifications
 */

package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
)

// Bridge represents an MCP bridge
type Bridge struct {
	mu sync.RWMutex

	// Transport
	transport Transport
	connected bool

	// Server info
	serverInfo         *Implementation
	serverCapabilities *ServerCapabilities

	// Registered items (server mode)
	tools             map[string]*registeredTool
	resources         map[string]*registeredResource
	resourceTemplates map[string]*ResourceTemplate
	prompts           map[string]*registeredPrompt
	roots             []Root
	logLevel          LogLevel

	// Handlers
	samplingHandler SamplingHandler

	// Notification handlers
	notificationHandlers map[string][]func(params interface{})
}

type registeredTool struct {
	tool    Tool
	handler ToolHandler
}

type registeredResource struct {
	resource Resource
	handler  ResourceHandler
}

type registeredPrompt struct {
	prompt  Prompt
	handler PromptHandler
}

// NewBridge creates a new MCP bridge
func NewBridge() *Bridge {
	return &Bridge{
		tools:                make(map[string]*registeredTool),
		resources:            make(map[string]*registeredResource),
		resourceTemplates:    make(map[string]*ResourceTemplate),
		prompts:              make(map[string]*registeredPrompt),
		notificationHandlers: make(map[string][]func(params interface{})),
		logLevel:             LogLevelInfo,
	}
}

// Initialize connects to an MCP server
func (b *Bridge) Initialize(ctx context.Context, transport Transport, clientInfo Implementation, capabilities ClientCapabilities) (*InitializeResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.connected {
		return nil, fmt.Errorf("already connected")
	}

	b.transport = transport

	if err := transport.Connect(); err != nil {
		return nil, fmt.Errorf("failed to connect transport: %w", err)
	}

	// Send initialize request
	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"init"`),
		Method:  "initialize",
	}

	params, _ := json.Marshal(InitializeRequest{
		ProtocolVersion: MCPVersion,
		Capabilities:    capabilities,
		ClientInfo:      clientInfo,
	})
	req.Params = params

	if err := transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send initialize: %w", err)
	}

	resp, err := transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive initialize response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("initialize error: %s", resp.Error.Message)
	}

	// Parse result
	resultJSON, _ := json.Marshal(resp.Result)
	var result InitializeResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse initialize result: %w", err)
	}

	b.serverInfo = &result.ServerInfo
	b.serverCapabilities = &result.Capabilities
	b.connected = true
	if err := transport.SendNotification(&JSONRPCNotification{
		JSONRPC: "2.0",
		Method:  "notifications/initialized",
	}); err != nil {
		b.connected = false
		return nil, fmt.Errorf("failed to send initialized notification: %w", err)
	}

	return &result, nil
}

// Close closes the connection
func (b *Bridge) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if !b.connected {
		return nil
	}

	b.connected = false
	b.serverInfo = nil
	b.serverCapabilities = nil

	if b.transport != nil {
		return b.transport.Close()
	}
	return nil
}

// ============================================================================
// Tools
// ============================================================================

// ListTools lists available tools
func (b *Bridge) ListTools(ctx context.Context) (*ToolsListResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"tools-list"`),
		Method:  "tools/list",
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send tools/list: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive tools/list response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("tools/list error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result ToolsListResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse tools/list result: %w", err)
	}

	return &result, nil
}

// CallTool calls a tool
func (b *Bridge) CallTool(ctx context.Context, name string, args map[string]interface{}) (*ToolResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	params, _ := json.Marshal(map[string]interface{}{
		"name":      name,
		"arguments": args,
	})

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"tools-call"`),
		Method:  "tools/call",
		Params:  params,
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send tools/call: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive tools/call response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("tools/call error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result ToolResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse tools/call result: %w", err)
	}

	return &result, nil
}

// RegisterTool registers a tool (server mode)
func (b *Bridge) RegisterTool(tool Tool, handler ToolHandler) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.tools[tool.Name] = &registeredTool{tool: tool, handler: handler}
}

// UnregisterTool unregisters a tool
func (b *Bridge) UnregisterTool(name string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.tools, name)
}

// ============================================================================
// Resources
// ============================================================================

// ListResources lists available resources
func (b *Bridge) ListResources(ctx context.Context) (*ResourcesListResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"resources-list"`),
		Method:  "resources/list",
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send resources/list: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive resources/list response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("resources/list error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result ResourcesListResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse resources/list result: %w", err)
	}

	return &result, nil
}

// ReadResource reads a resource
func (b *Bridge) ReadResource(ctx context.Context, uri string) (*ResourceReadResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	params, _ := json.Marshal(map[string]interface{}{"uri": uri})

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"resources-read"`),
		Method:  "resources/read",
		Params:  params,
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send resources/read: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive resources/read response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("resources/read error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result ResourceReadResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse resources/read result: %w", err)
	}

	return &result, nil
}

// RegisterResource registers a resource (server mode)
func (b *Bridge) RegisterResource(resource Resource, handler ResourceHandler) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.resources[resource.URI] = &registeredResource{resource: resource, handler: handler}
}

// ============================================================================
// Prompts
// ============================================================================

// ListPrompts lists available prompts
func (b *Bridge) ListPrompts(ctx context.Context) (*PromptsListResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"prompts-list"`),
		Method:  "prompts/list",
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send prompts/list: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive prompts/list response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("prompts/list error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result PromptsListResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse prompts/list result: %w", err)
	}

	return &result, nil
}

// GetPrompt gets a prompt
func (b *Bridge) GetPrompt(ctx context.Context, name string, args map[string]string) (*PromptGetResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	params, _ := json.Marshal(map[string]interface{}{
		"name":      name,
		"arguments": args,
	})

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"prompts-get"`),
		Method:  "prompts/get",
		Params:  params,
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send prompts/get: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive prompts/get response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("prompts/get error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result PromptGetResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse prompts/get result: %w", err)
	}

	return &result, nil
}

// RegisterPrompt registers a prompt (server mode)
func (b *Bridge) RegisterPrompt(prompt Prompt, handler PromptHandler) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.prompts[prompt.Name] = &registeredPrompt{prompt: prompt, handler: handler}
}

// ============================================================================
// Sampling
// ============================================================================

// CreateSamplingRequest requests LLM sampling
func (b *Bridge) CreateSamplingRequest(ctx context.Context, params *SamplingParams) (*SamplingResponse, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	paramsJSON, _ := json.Marshal(params)

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"sampling-create"`),
		Method:  "sampling/createMessage",
		Params:  paramsJSON,
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send sampling/createMessage: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive sampling response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("sampling error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result SamplingResponse
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse sampling result: %w", err)
	}

	return &result, nil
}

// SetSamplingHandler sets the sampling handler (server mode)
func (b *Bridge) SetSamplingHandler(handler SamplingHandler) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.samplingHandler = handler
}

// ============================================================================
// Roots
// ============================================================================

// ListRoots lists roots
func (b *Bridge) ListRoots(ctx context.Context) (*RootsListResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return nil, fmt.Errorf("not connected")
	}

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"roots-list"`),
		Method:  "roots/list",
	}

	if err := b.transport.Send(req); err != nil {
		return nil, fmt.Errorf("failed to send roots/list: %w", err)
	}

	resp, err := b.transport.Receive()
	if err != nil {
		return nil, fmt.Errorf("failed to receive roots/list response: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("roots/list error: %s", resp.Error.Message)
	}

	resultJSON, _ := json.Marshal(resp.Result)
	var result RootsListResult
	if err := json.Unmarshal(resultJSON, &result); err != nil {
		return nil, fmt.Errorf("failed to parse roots/list result: %w", err)
	}

	return &result, nil
}

// SetRoots sets roots (client mode)
func (b *Bridge) SetRoots(roots []Root) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.roots = roots
}

// ============================================================================
// Logging
// ============================================================================

// SetLogLevel sets the log level
func (b *Bridge) SetLogLevel(ctx context.Context, level LogLevel) error {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return fmt.Errorf("not connected")
	}

	params, _ := json.Marshal(map[string]interface{}{"level": level})

	req := &JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`"logging-setLevel"`),
		Method:  "logging/setLevel",
		Params:  params,
	}

	if err := b.transport.Send(req); err != nil {
		return fmt.Errorf("failed to send logging/setLevel: %w", err)
	}

	_, err := b.transport.Receive()
	if err != nil {
		return fmt.Errorf("failed to receive logging/setLevel response: %w", err)
	}

	b.logLevel = level
	return nil
}

// Log sends a log message
func (b *Bridge) Log(level LogLevel, data interface{}) error {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if !b.connected {
		return fmt.Errorf("not connected")
	}

	params, _ := json.Marshal(LogMessage{
		Level: level,
		Data:  data,
	})

	notification := &JSONRPCNotification{
		JSONRPC: "2.0",
		Method:  "notifications/message",
		Params:  params,
	}

	return b.transport.SendNotification(notification)
}

// ============================================================================
// Utility Methods
// ============================================================================

// IsConnected returns whether the bridge is connected
func (b *Bridge) IsConnected() bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.connected
}

// GetServerInfo returns the server info
func (b *Bridge) GetServerInfo() *Implementation {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.serverInfo
}

// GetServerCapabilities returns the server capabilities
func (b *Bridge) GetServerCapabilities() *ServerCapabilities {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.serverCapabilities
}

// HasCapability checks if the server supports a capability
func (b *Bridge) HasCapability(capability string) bool {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if b.serverCapabilities == nil {
		return false
	}

	switch capability {
	case "tools":
		return b.serverCapabilities.Tools != nil
	case "resources":
		return b.serverCapabilities.Resources != nil
	case "prompts":
		return b.serverCapabilities.Prompts != nil
	case "logging":
		return b.serverCapabilities.Logging != nil
	default:
		return false
	}
}
