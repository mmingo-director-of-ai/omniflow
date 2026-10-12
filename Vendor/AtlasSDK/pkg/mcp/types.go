/**
 * MCP Types - Model Context Protocol type definitions (Go SDK)
 *
 * Based on MCP specification version 2025-11-25
 */

package mcp

import (
	"encoding/json"
	"fmt"
)

// MCPVersion is the protocol version
const MCPVersion = "2025-11-25"

// JSONRPCRequest represents a JSON-RPC request
type JSONRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// JSONRPCResponse represents a JSON-RPC response
type JSONRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *JSONRPCError   `json:"error,omitempty"`
}

// JSONRPCError represents a JSON-RPC error
type JSONRPCError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

// JSONRPCNotification represents a JSON-RPC notification
type JSONRPCNotification struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// ClientCapabilities represents client capabilities
type ClientCapabilities struct {
	Experimental map[string]interface{} `json:"experimental,omitempty"`
	Roots        *RootsCapability       `json:"roots,omitempty"`
	Sampling     map[string]interface{} `json:"sampling,omitempty"`
}

// RootsCapability represents roots capability
type RootsCapability struct {
	ListChanged bool `json:"listChanged,omitempty"`
}

// ServerCapabilities represents server capabilities
type ServerCapabilities struct {
	Experimental map[string]interface{} `json:"experimental,omitempty"`
	Tools        *ToolsCapability       `json:"tools,omitempty"`
	Resources    *ResourcesCapability   `json:"resources,omitempty"`
	Prompts      *PromptsCapability     `json:"prompts,omitempty"`
	Logging      map[string]interface{} `json:"logging,omitempty"`
}

// ToolsCapability represents tools capability
type ToolsCapability struct {
	ListChanged bool `json:"listChanged,omitempty"`
}

// ResourcesCapability represents resources capability
type ResourcesCapability struct {
	Subscribe   bool `json:"subscribe,omitempty"`
	ListChanged bool `json:"listChanged,omitempty"`
}

// PromptsCapability represents prompts capability
type PromptsCapability struct {
	ListChanged bool `json:"listChanged,omitempty"`
}

// Implementation represents implementation info
type Implementation struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// Tool represents a tool definition
type Tool struct {
	Name        string      `json:"name"`
	Description string      `json:"description,omitempty"`
	InputSchema InputSchema `json:"inputSchema"`
}

// InputSchema represents a tool input schema
type InputSchema struct {
	Type       string                 `json:"type"` // Always "object"
	Properties map[string]PropertyDef `json:"properties,omitempty"`
	Required   []string               `json:"required,omitempty"`
}

// PropertyDef represents a property definition
type PropertyDef struct {
	Type        string      `json:"type"`
	Description string      `json:"description,omitempty"`
	Enum        []string    `json:"enum,omitempty"`
	Default     interface{} `json:"default,omitempty"`
}

// ToolResult represents a tool execution result
type ToolResult struct {
	Content           []ContentBlock         `json:"content"`
	StructuredContent map[string]interface{} `json:"structuredContent,omitempty"`
	IsError           bool                   `json:"isError,omitempty"`
}

// UnmarshalJSON preserves the concrete MCP content-block type. Decoding
// directly into []ContentBlock would otherwise fail because it is an interface.
func (r *ToolResult) UnmarshalJSON(data []byte) error {
	var wire struct {
		Content           []json.RawMessage      `json:"content"`
		StructuredContent map[string]interface{} `json:"structuredContent,omitempty"`
		IsError           bool                   `json:"isError,omitempty"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	r.IsError = wire.IsError
	r.StructuredContent = wire.StructuredContent
	r.Content = make([]ContentBlock, 0, len(wire.Content))
	for _, raw := range wire.Content {
		var discriminator struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &discriminator); err != nil {
			return err
		}
		var block ContentBlock
		switch discriminator.Type {
		case "text":
			block = &TextContent{}
		case "image":
			block = &ImageContent{}
		case "audio":
			block = &AudioContent{}
		case "resource_link":
			block = &ResourceLinkContent{}
		case "resource":
			block = &ResourceContent{}
		default:
			return fmt.Errorf("unsupported MCP content type %q", discriminator.Type)
		}
		if err := json.Unmarshal(raw, block); err != nil {
			return err
		}
		r.Content = append(r.Content, block)
	}
	return nil
}

// ContentBlock represents a content block
type ContentBlock interface {
	ContentType() string
}

// TextContent represents text content
type TextContent struct {
	Type string `json:"type"` // "text"
	Text string `json:"text"`
}

// ContentType returns the content type
func (t TextContent) ContentType() string { return "text" }

// ImageContent represents image content
type ImageContent struct {
	Type     string `json:"type"` // "image"
	Data     string `json:"data"` // base64
	MimeType string `json:"mimeType"`
}

// ContentType returns the content type
func (i ImageContent) ContentType() string { return "image" }

// AudioContent represents base64-encoded audio returned by a tool.
type AudioContent struct {
	Type     string `json:"type"`
	Data     string `json:"data"`
	MimeType string `json:"mimeType"`
}

// ContentType returns the content type.
func (a AudioContent) ContentType() string { return "audio" }

// ResourceLinkContent points to a resource without embedding its contents.
type ResourceLinkContent struct {
	Type        string `json:"type"`
	URI         string `json:"uri"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	MimeType    string `json:"mimeType,omitempty"`
	Size        int64  `json:"size,omitempty"`
}

// ContentType returns the content type.
func (r ResourceLinkContent) ContentType() string { return "resource_link" }

// ResourceContent represents resource content
type ResourceContent struct {
	Type     string `json:"type"` // "resource"
	URI      string `json:"uri"`
	MimeType string `json:"mimeType,omitempty"`
	Text     string `json:"text,omitempty"`
	Blob     string `json:"blob,omitempty"` // base64
}

// UnmarshalJSON accepts the current nested embedded-resource shape and the
// legacy flat projection retained by the Go public API.
func (r *ResourceContent) UnmarshalJSON(data []byte) error {
	type flat ResourceContent
	var wire struct {
		Type     string `json:"type"`
		Resource *flat  `json:"resource"`
		URI      string `json:"uri"`
		MimeType string `json:"mimeType,omitempty"`
		Text     string `json:"text,omitempty"`
		Blob     string `json:"blob,omitempty"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if wire.Resource != nil {
		*r = ResourceContent(*wire.Resource)
		r.Type = wire.Type
		return nil
	}
	*r = ResourceContent{Type: wire.Type, URI: wire.URI, MimeType: wire.MimeType, Text: wire.Text, Blob: wire.Blob}
	return nil
}

// ContentType returns the content type
func (r ResourceContent) ContentType() string { return "resource" }

// Resource represents a resource definition
type Resource struct {
	URI         string `json:"uri"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	MimeType    string `json:"mimeType,omitempty"`
}

// ResourceTemplate represents a resource template
type ResourceTemplate struct {
	URITemplate string `json:"uriTemplate"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	MimeType    string `json:"mimeType,omitempty"`
}

// Prompt represents a prompt definition
type Prompt struct {
	Name        string           `json:"name"`
	Description string           `json:"description,omitempty"`
	Arguments   []PromptArgument `json:"arguments,omitempty"`
}

// PromptArgument represents a prompt argument
type PromptArgument struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Required    bool   `json:"required,omitempty"`
}

// PromptMessage represents a prompt message
type PromptMessage struct {
	Role    string       `json:"role"` // "user" or "assistant"
	Content ContentBlock `json:"content"`
}

// SamplingParams represents sampling parameters
type SamplingParams struct {
	Messages         []SamplingMessage      `json:"messages"`
	ModelPreferences *ModelPreferences      `json:"modelPreferences,omitempty"`
	SystemPrompt     string                 `json:"systemPrompt,omitempty"`
	IncludeContext   string                 `json:"includeContext,omitempty"` // "none", "thisServer", "allServers"
	Temperature      *float64               `json:"temperature,omitempty"`
	MaxTokens        int                    `json:"maxTokens"`
	StopSequences    []string               `json:"stopSequences,omitempty"`
	Metadata         map[string]interface{} `json:"metadata,omitempty"`
}

// SamplingMessage represents a sampling message
type SamplingMessage struct {
	Role    string       `json:"role"` // "user" or "assistant"
	Content ContentBlock `json:"content"`
}

// ModelPreferences represents model preferences
type ModelPreferences struct {
	Hints                []ModelHint `json:"hints,omitempty"`
	CostPriority         *float64    `json:"costPriority,omitempty"`
	SpeedPriority        *float64    `json:"speedPriority,omitempty"`
	IntelligencePriority *float64    `json:"intelligencePriority,omitempty"`
}

// ModelHint represents a model hint
type ModelHint struct {
	Name string `json:"name,omitempty"`
}

// SamplingResponse represents a sampling response
type SamplingResponse struct {
	Model      string       `json:"model"`
	StopReason string       `json:"stopReason,omitempty"` // "endTurn", "stopSequence", "maxTokens"
	Content    ContentBlock `json:"content"`
}

// Root represents a root definition
type Root struct {
	URI  string `json:"uri"`
	Name string `json:"name,omitempty"`
}

// LogLevel represents a log level
type LogLevel string

const (
	LogLevelDebug     LogLevel = "debug"
	LogLevelInfo      LogLevel = "info"
	LogLevelNotice    LogLevel = "notice"
	LogLevelWarning   LogLevel = "warning"
	LogLevelError     LogLevel = "error"
	LogLevelCritical  LogLevel = "critical"
	LogLevelAlert     LogLevel = "alert"
	LogLevelEmergency LogLevel = "emergency"
)

// LogMessage represents a log message
type LogMessage struct {
	Level  LogLevel    `json:"level"`
	Data   interface{} `json:"data"`
	Logger string      `json:"logger,omitempty"`
}

// InitializeRequest represents an initialize request
type InitializeRequest struct {
	ProtocolVersion string             `json:"protocolVersion"`
	Capabilities    ClientCapabilities `json:"capabilities"`
	ClientInfo      Implementation     `json:"clientInfo"`
}

// InitializeResult represents an initialize result
type InitializeResult struct {
	ProtocolVersion string             `json:"protocolVersion"`
	Capabilities    ServerCapabilities `json:"capabilities"`
	ServerInfo      Implementation     `json:"serverInfo"`
}

// ToolsListResult represents a tools/list result
type ToolsListResult struct {
	Tools      []Tool `json:"tools"`
	NextCursor string `json:"nextCursor,omitempty"`
}

// ResourcesListResult represents a resources/list result
type ResourcesListResult struct {
	Resources  []Resource `json:"resources"`
	NextCursor string     `json:"nextCursor,omitempty"`
}

// ResourceReadResult represents a resources/read result
type ResourceReadResult struct {
	Contents []ResourceContent `json:"contents"`
}

// PromptsListResult represents a prompts/list result
type PromptsListResult struct {
	Prompts    []Prompt `json:"prompts"`
	NextCursor string   `json:"nextCursor,omitempty"`
}

// PromptGetResult represents a prompts/get result
type PromptGetResult struct {
	Description string          `json:"description,omitempty"`
	Messages    []PromptMessage `json:"messages"`
}

// RootsListResult represents a roots/list result
type RootsListResult struct {
	Roots []Root `json:"roots"`
}

// Transport interface for MCP communication
type Transport interface {
	Connect() error
	Close() error
	Send(request *JSONRPCRequest) error
	SendNotification(notification *JSONRPCNotification) error
	Receive() (*JSONRPCResponse, error)
	OnError(handler func(error))
	OnClose(handler func())
}

// ToolHandler is a function that handles tool calls
type ToolHandler func(args map[string]interface{}) (*ToolResult, error)

// ResourceHandler is a function that handles resource reads
type ResourceHandler func(uri string) (*ResourceContent, error)

// PromptHandler is a function that handles prompt requests
type PromptHandler func(args map[string]string) ([]PromptMessage, error)

// SamplingHandler is a function that handles sampling requests
type SamplingHandler func(params *SamplingParams) (*SamplingResponse, error)
