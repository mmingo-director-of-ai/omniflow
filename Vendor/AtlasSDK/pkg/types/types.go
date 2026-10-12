// Package types provides core type definitions for Atlas SDK Go.
package types

import "errors"

// ProviderType represents supported LLM provider types.
type ProviderType string

const (
	ProviderOllama           ProviderType = "ollama"
	ProviderOpenAI           ProviderType = "openai"
	ProviderAnthropic        ProviderType = "anthropic"
	ProviderAzure            ProviderType = "azure"
	ProviderBedrock          ProviderType = "bedrock"
	ProviderGoogle           ProviderType = "google"
	ProviderOpenAICompatible ProviderType = "openai-compatible"
)

// AtlasConfig holds the main configuration for Atlas.
type AtlasConfig struct {
	Provider     *ProviderType
	Model        *string
	BaseURL      *string
	APIKey       *string
	Providers    []ProviderConfig
	MCPServers   []MCPServerConfig
	Talents      []TalentConfig
	MaxSteps     *int
	Temperature  *float64
	MaxTokens    *int
	SystemPrompt *string
}

// ProviderConfig holds configuration for a single provider.
type ProviderConfig struct {
	Type      ProviderType
	Model     string
	BaseURL   string
	APIKey    string
	Priority  int
	Region    string
	ProjectID string
}

// MCPServerConfig holds configuration for an MCP server.
type MCPServerConfig struct {
	Name      string
	Transport MCPTransportConfig
}

// MCPTransportConfig holds transport-specific configuration.
type MCPTransportConfig struct {
	Type    string            // "stdio", "http", "sse"
	Command string            // for stdio
	Args    []string          // for stdio
	Env     map[string]string // for stdio
	URL     string            // for http/sse
	Headers map[string]string // for http/sse
}

// TalentConfig holds configuration for a talent.
type TalentConfig struct {
	Name    string
	Path    string
	Enabled bool
}

// Message represents a chat message.
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	Name       string     `json:"name,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
}

// Tool represents a callable tool.
type Tool struct {
	Name        string
	Description string
	InputSchema map[string]interface{}
	Handler     func(args map[string]interface{}, ctx ToolContext) (interface{}, error)
}

// ToolContext provides context to tool handlers.
type ToolContext struct {
	ToolName string
	Atlas    interface{}
}

// ToolCall represents a tool invocation.
type ToolCall struct {
	ID        string                 `json:"id,omitempty"`
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
	Result    interface{}            `json:"result,omitempty"`
	Duration  int64                  `json:"duration,omitempty"`
	Success   bool                   `json:"success,omitempty"`
	Error     string                 `json:"error,omitempty"`
}

// ExecutionResult holds the result of an execute call.
type ExecutionResult struct {
	Text         string
	ToolCalls    []ToolCall
	FinishReason string
	Steps        []Step
	Usage        *Usage
}

// Step represents a single step in execution.
type Step struct {
	Step     int                    `json:"step"`
	Role     string                 `json:"role"`
	Content  string                 `json:"content"`
	ToolName string                 `json:"tool_name,omitempty"`
	ToolArgs map[string]interface{} `json:"tool_args,omitempty"`
}

// Usage tracks token usage.
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// ExecuteOptions holds options for execute calls.
type ExecuteOptions struct {
	Messages     []Message
	Tools        []string
	MaxSteps     *int
	Temperature  *float64
	MaxTokens    *int
	SystemPrompt *string
	OnToolCall   func(tool string, args map[string]interface{})
	OnStep       func(step int, result string)
}

// AtlasState represents the current state of Atlas.
type AtlasState struct {
	IsInitialized       bool
	CurrentProvider     string
	ConnectedMCPServers []string
	LoadedTalents       []string
	RegisteredTools     []string
	MessageCount        int
}

// ProviderResponse is returned by providers.
type ProviderResponse struct {
	Content      string
	ToolCalls    []ProviderToolCall
	FinishReason string
	Usage        *Usage
}

// ProviderToolCall is a tool call from a provider.
type ProviderToolCall struct {
	ID        string
	Name      string
	Arguments map[string]interface{}
}

// StreamChunk represents a chunk of streamed content.
type StreamChunk struct {
	Type         string // "content", "tool_call", "finish"
	Content      string
	ToolCall     *ProviderToolCall
	FinishReason string
}

// GenerateOptions holds options for generation.
type GenerateOptions struct {
	Messages    []Message
	Tools       []Tool
	Temperature *float64
	MaxTokens   *int
	Stop        []string
	Stream      bool
}

// ProviderCapabilities describes what a provider supports.
type ProviderCapabilities struct {
	SupportsStreaming bool
	SupportsTools     bool
	SupportsVision    bool
	MaxContextLength  int
}

// Error types.

// AtlasError is the base error type.
type AtlasError struct {
	Code    string
	Message string
}

func (e *AtlasError) Error() string {
	return e.Message
}

// ProviderError is returned when a provider fails.
type ProviderError struct {
	AtlasError
	Provider   string
	StatusCode int
}

func NewProviderError(message, provider string, statusCode int) *ProviderError {
	return &ProviderError{
		AtlasError: AtlasError{Code: "PROVIDER_ERROR", Message: message},
		Provider:   provider,
		StatusCode: statusCode,
	}
}

// ToolError is returned when a tool fails.
type ToolError struct {
	AtlasError
	Tool string
	Args map[string]interface{}
}

func NewToolError(message, tool string, args map[string]interface{}) *ToolError {
	return &ToolError{
		AtlasError: AtlasError{Code: "TOOL_ERROR", Message: message},
		Tool:       tool,
		Args:       args,
	}
}

// MCPServerError is returned when an MCP server fails.
type MCPServerError struct {
	AtlasError
	Server    string
	Transport string
}

func NewMCPServerError(message, server, transport string) *MCPServerError {
	return &MCPServerError{
		AtlasError: AtlasError{Code: "MCP_SERVER_ERROR", Message: message},
		Server:     server,
		Transport:  transport,
	}
}

// TalentError is returned when a talent fails to load.
type TalentError struct {
	AtlasError
	Talent string
}

func NewTalentError(message, talent string) *TalentError {
	return &TalentError{
		AtlasError: AtlasError{Code: "TALENT_ERROR", Message: message},
		Talent:     talent,
	}
}

// Common errors.
var (
	ErrNotInitialized      = errors.New("atlas not initialized, call Initialize() first")
	ErrNoProviders         = errors.New("no providers registered")
	ErrNoAvailableProvider = errors.New("no available providers")
)
