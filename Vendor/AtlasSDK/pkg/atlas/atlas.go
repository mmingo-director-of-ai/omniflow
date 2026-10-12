// Package atlas provides the core Atlas functionality for Go
package atlas

import (
	"context"
	"encoding/json"
	"fmt"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/mcp"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/providers"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/subagent"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/talents"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/tools"
)

// Atlas is the main orchestration type
type Atlas struct {
	config           *Config
	providerRegistry *providers.ProviderRegistry
	mcpManager       mcpManager
	talentLoader     *talents.Loader
	tools            *tools.Registry
	messages         []Message
	enabledTalents   map[string]bool
	talentTools      map[string][]string // talent name -> tool names
	subAgentRunner   *subagent.Runner
	initialized      bool
}

type mcpManager interface {
	Connect(context.Context, string, mcp.TransportConfig) ([]mcp.Tool, error)
	CallTool(context.Context, string, string, map[string]interface{}) (*mcp.ToolResult, error)
	ListServers() []string
	Disconnect(context.Context, string) error
	DisconnectAll(context.Context) error
}

// Config holds Atlas configuration
type Config struct {
	Provider     string
	Model        string
	BaseURL      string
	APIKey       string
	Providers    []ProviderConfig
	MCPServers   []MCPServerConfig
	Talents      []TalentConfig
	MaxSteps     int
	Temperature  float64
	MaxTokens    int
	SystemPrompt string
}

// ProviderConfig configures a provider
type ProviderConfig struct {
	Type     string
	Model    string
	BaseURL  string
	APIKey   string
	Priority int
	Region   string
}

// MCPServerConfig configures an MCP server
type MCPServerConfig struct {
	Name string
	// ToolPrefix is prepended to discovered tool names. Use it when two MCP
	// servers expose the same name; duplicate exposed names are rejected.
	ToolPrefix string
	Transport  MCPTransportConfig
}

// MCPTransportConfig configures MCP transport
type MCPTransportConfig struct {
	Type    string
	Command string
	Args    []string
	Env     map[string]string
	URL     string
	Headers map[string]string
}

// TalentConfig configures a talent
type TalentConfig struct {
	Name    string
	Path    string
	Enabled bool
}

// Message represents a chat message
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	Name       string     `json:"name,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
}

// ToolCall represents a tool invocation
type ToolCall struct {
	ID        string                 `json:"id"`
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
}

// ExecutionResult is the result of an execute call
type ExecutionResult struct {
	Text         string           `json:"text"`
	ToolCalls    []ToolCallResult `json:"tool_calls"`
	FinishReason string           `json:"finish_reason"`
	Steps        []Step           `json:"steps"`
	Usage        *Usage           `json:"usage,omitempty"`
}

// ToolCallResult includes execution results
type ToolCallResult struct {
	ToolCall
	Result   interface{} `json:"result,omitempty"`
	Duration int64       `json:"duration"`
	Success  bool        `json:"success"`
	Error    string      `json:"error,omitempty"`
}

// Step represents a step in execution
type Step struct {
	Step     int                    `json:"step"`
	Role     string                 `json:"role"`
	Content  string                 `json:"content"`
	ToolName string                 `json:"tool_name,omitempty"`
	ToolArgs map[string]interface{} `json:"tool_args,omitempty"`
}

// Usage tracks token usage
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// ExecuteOptions configures execution
type ExecuteOptions struct {
	Messages     []Message
	Tools        []string
	MaxSteps     int
	Temperature  *float64
	MaxTokens    *int
	SystemPrompt string
	OnToolCall   func(tool string, args map[string]interface{})
	OnStep       func(step int, content string)
}

// StreamChunk represents a streaming response chunk
type StreamChunk struct {
	Type         string    `json:"type"`
	Content      string    `json:"content,omitempty"`
	ToolCall     *ToolCall `json:"tool_call,omitempty"`
	FinishReason string    `json:"finish_reason,omitempty"`
}

// State represents current Atlas state
type State struct {
	IsInitialized       bool     `json:"is_initialized"`
	CurrentProvider     string   `json:"current_provider,omitempty"`
	ConnectedMCPServers []string `json:"connected_mcp_servers"`
	LoadedTalents       []string `json:"loaded_talents"`
	RegisteredTools     []string `json:"registered_tools"`
	MessageCount        int      `json:"message_count"`
}

// New creates a new Atlas instance
func New(cfg *Config) *Atlas {
	if cfg == nil {
		cfg = &Config{}
	}
	if cfg.MaxSteps == 0 {
		cfg.MaxSteps = 10
	}
	if cfg.Temperature == 0 {
		cfg.Temperature = 0.7
	}

	a := &Atlas{
		config:           cfg,
		providerRegistry: providers.NewProviderRegistry(),
		mcpManager:       mcp.NewManager(),
		talentLoader:     talents.NewLoader(),
		tools:            tools.NewRegistry(),
		enabledTalents:   make(map[string]bool),
		talentTools:      make(map[string][]string),
	}

	// Register providers
	if len(cfg.Providers) > 0 {
		for _, pc := range cfg.Providers {
			a.providerRegistry.Register(providers.ProviderConfig{
				Type:     providers.ProviderType(pc.Type),
				Model:    pc.Model,
				BaseURL:  pc.BaseURL,
				APIKey:   pc.APIKey,
				Priority: pc.Priority,
				Region:   pc.Region,
			})
		}
	} else if cfg.Provider != "" {
		a.providerRegistry.Register(providers.ProviderConfig{
			Type:     providers.ProviderType(cfg.Provider),
			Model:    cfg.Model,
			BaseURL:  cfg.BaseURL,
			APIKey:   cfg.APIKey,
			Priority: 1,
		})
	}

	// Set system prompt
	if cfg.SystemPrompt != "" {
		a.messages = append(a.messages, Message{
			Role:    "system",
			Content: cfg.SystemPrompt,
		})
	}

	return a
}

// Initialize sets up the Atlas instance
func (a *Atlas) Initialize(ctx context.Context) error {
	// Initialize provider
	provider, err := a.providerRegistry.GetAvailable(ctx)
	if err != nil {
		return fmt.Errorf("no available providers: %w", err)
	}

	if err := provider.Initialize(ctx); err != nil {
		return fmt.Errorf("failed to initialize provider: %w", err)
	}

	// Connect MCP servers
	for _, server := range a.config.MCPServers {
		mcpTools, err := a.mcpManager.Connect(ctx, server.Name, mcp.TransportConfig{
			Type:    server.Transport.Type,
			Command: server.Transport.Command,
			Args:    server.Transport.Args,
			Env:     server.Transport.Env,
			URL:     server.Transport.URL,
			Headers: server.Transport.Headers,
		})
		if err != nil {
			// Log warning but continue
			continue
		}
		// Register MCP tools. The callable closure retains the originating
		// server so model calls cannot be routed to a same-named peer tool.
		for _, mt := range mcpTools {
			exposedName := server.ToolPrefix + mt.Name
			if err := a.tools.Register(adaptMCPTool(server.Name, exposedName, mt, a.mcpManager)); err != nil {
				_ = a.mcpManager.Disconnect(ctx, server.Name)
				return fmt.Errorf("register MCP tool %s from %s: %w", mt.Name, server.Name, err)
			}
		}
	}

	// Load talents
	for _, tc := range a.config.Talents {
		if tc.Enabled {
			if _, err := a.talentLoader.LoadFromDirectory(tc.Path); err != nil {
				continue
			}
			a.enabledTalents[tc.Name] = true
		}
	}

	a.initialized = true
	return nil
}

// Execute runs a prompt with optional tool calling
func (a *Atlas) Execute(ctx context.Context, opts ExecuteOptions) (*ExecutionResult, error) {
	provider, err := a.providerRegistry.GetAvailable(ctx)
	if err != nil {
		return nil, fmt.Errorf("no provider available: %w", err)
	}

	maxSteps := opts.MaxSteps
	if maxSteps == 0 {
		maxSteps = a.config.MaxSteps
	}

	// Prepare messages
	messages := make([]providers.Message, 0, len(a.messages)+len(opts.Messages))
	for _, m := range a.messages {
		messages = append(messages, providers.Message{
			Role:    m.Role,
			Content: m.Content,
			Name:    m.Name,
		})
	}
	for _, m := range opts.Messages {
		messages = append(messages, providers.Message{
			Role:       m.Role,
			Content:    m.Content,
			Name:       m.Name,
			ToolCallID: m.ToolCallID,
		})
	}

	// Get enabled tools
	enabledTools := a.getEnabledTools(opts.Tools)
	providerTools := make([]providers.Tool, len(enabledTools))
	for i, t := range enabledTools {
		providerTools[i] = providers.Tool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: t.InputSchema,
		}
	}

	temperature := opts.Temperature
	if temperature == nil {
		temp := a.config.Temperature
		temperature = &temp
	}

	maxTokens := opts.MaxTokens
	if maxTokens == nil {
		tokens := a.config.MaxTokens
		maxTokens = &tokens
	}

	// Execute with tool loop
	var steps []Step
	var executedTools []ToolCallResult
	finishReason := "stop"

	for step := 0; step < maxSteps; step++ {
		resp, err := provider.Generate(ctx, providers.GenerateOptions{
			Messages:    messages,
			Tools:       providerTools,
			Temperature: *temperature,
			MaxTokens:   *maxTokens,
		})
		if err != nil {
			return nil, fmt.Errorf("provider error: %w", err)
		}

		// Add assistant message
		messages = append(messages, providers.Message{
			Role:    "assistant",
			Content: resp.Content,
		})

		steps = append(steps, Step{
			Step:    step + 1,
			Role:    "assistant",
			Content: resp.Content,
		})

		if opts.OnStep != nil {
			opts.OnStep(step+1, resp.Content)
		}

		// Check if done
		if len(resp.ToolCalls) == 0 {
			finishReason = resp.FinishReason
			break
		}

		// Execute tool calls
		for _, tc := range resp.ToolCalls {
			if opts.OnToolCall != nil {
				opts.OnToolCall(tc.Name, tc.Arguments)
			}

			result, err := a.tools.Execute(ctx, tc.Name, tc.Arguments, a)
			tcr := ToolCallResult{
				ToolCall: ToolCall{
					ID:        tc.ID,
					Name:      tc.Name,
					Arguments: tc.Arguments,
				},
				Success: result.Success,
			}
			if err != nil {
				tcr.Error = err.Error()
			} else if !result.Success {
				tcr.Error = result.Error
			} else {
				tcr.Result = result.Data
			}
			executedTools = append(executedTools, tcr)

			// Add tool result to messages
			resultJSON, _ := json.Marshal(map[string]interface{}{
				"result": result.Data,
				"error":  tcr.Error,
			})
			messages = append(messages, providers.Message{
				Role:       "tool",
				Content:    string(resultJSON),
				ToolCallID: tc.ID,
			})

			steps = append(steps, Step{
				Step:     step + 1,
				Role:     "tool",
				Content:  string(resultJSON),
				ToolName: tc.Name,
				ToolArgs: tc.Arguments,
			})
		}

		if step == maxSteps-1 {
			finishReason = "max_steps"
		}
	}

	return &ExecutionResult{
		Text:         messages[len(messages)-1].Content,
		ToolCalls:    executedTools,
		FinishReason: finishReason,
		Steps:        steps,
	}, nil
}

// ExecuteStream runs with streaming response
func (a *Atlas) ExecuteStream(ctx context.Context, opts ExecuteOptions, onChunk func(StreamChunk)) (*ExecutionResult, error) {
	provider, err := a.providerRegistry.GetAvailable(ctx)
	if err != nil {
		return nil, fmt.Errorf("no provider available: %w", err)
	}

	// Prepare messages
	messages := make([]providers.Message, 0, len(a.messages)+len(opts.Messages))
	for _, m := range a.messages {
		messages = append(messages, providers.Message{
			Role:    m.Role,
			Content: m.Content,
			Name:    m.Name,
		})
	}
	for _, m := range opts.Messages {
		messages = append(messages, providers.Message{
			Role:       m.Role,
			Content:    m.Content,
			Name:       m.Name,
			ToolCallID: m.ToolCallID,
		})
	}

	temperature := opts.Temperature
	if temperature == nil {
		temp := a.config.Temperature
		temperature = &temp
	}

	maxTokens := opts.MaxTokens
	if maxTokens == nil {
		tokens := a.config.MaxTokens
		maxTokens = &tokens
	}

	var fullContent string
	onProviderChunk := func(chunk providers.StreamChunk) {
		switch chunk.Type {
		case "content":
			fullContent += chunk.Content
			onChunk(StreamChunk{Type: "content", Content: chunk.Content})
		case "tool_call":
			onChunk(StreamChunk{Type: "tool", ToolCall: (*ToolCall)(chunk.ToolCall)})
		case "finish":
			onChunk(StreamChunk{Type: "finish", FinishReason: chunk.FinishReason})
		}
	}

	resp, err := provider.GenerateStream(ctx, providers.GenerateOptions{
		Messages:    messages,
		Temperature: *temperature,
		MaxTokens:   *maxTokens,
	}, onProviderChunk)
	if err != nil {
		return nil, fmt.Errorf("streaming error: %w", err)
	}

	return &ExecutionResult{
		Text:         fullContent,
		FinishReason: resp.FinishReason,
		Steps: []Step{
			{Step: 1, Role: "assistant", Content: fullContent},
		},
	}, nil
}

// RegisterTool registers a custom tool
func (a *Atlas) RegisterTool(tool tools.Tool) error {
	return a.tools.Register(tool)
}

// RegisterTools registers multiple tools
func (a *Atlas) RegisterTools(tools []tools.Tool) error {
	return a.tools.RegisterMultiple(tools)
}

// ListTools returns all registered tools
func (a *Atlas) ListTools() []tools.Tool {
	return a.tools.List()
}

// GetTool returns a specific tool
func (a *Atlas) GetTool(name string) (tools.Tool, bool) {
	return a.tools.Get(name)
}

// GetState returns current state
func (a *Atlas) GetState() State {
	return State{
		IsInitialized:       a.initialized,
		CurrentProvider:     a.config.Provider,
		ConnectedMCPServers: a.mcpManager.ListServers(),
		LoadedTalents:       a.talentLoader.ListNames(),
		RegisteredTools:     a.tools.ListNames(),
		MessageCount:        len(a.messages),
	}
}

type mcpToolCaller interface {
	CallTool(context.Context, string, string, map[string]interface{}) (*mcp.ToolResult, error)
}

func adaptMCPTool(serverName, exposedName string, definition mcp.Tool, caller mcpToolCaller) tools.Tool {
	schemaJSON, _ := json.Marshal(definition.InputSchema)
	var schema map[string]interface{}
	_ = json.Unmarshal(schemaJSON, &schema)
	if schema == nil {
		schema = map[string]interface{}{"type": "object"}
	}
	return tools.Tool{
		Name:        exposedName,
		Description: definition.Description,
		InputSchema: schema,
		Handler: func(ctx context.Context, args map[string]interface{}, _ tools.Context) (interface{}, error) {
			result, err := caller.CallTool(ctx, serverName, definition.Name, args)
			if err != nil {
				return nil, fmt.Errorf("MCP tool %s/%s failed: %w", serverName, definition.Name, err)
			}
			if result.IsError {
				return nil, fmt.Errorf("MCP tool %s/%s returned an error", serverName, definition.Name)
			}
			return result, nil
		},
	}
}

// ClearHistory clears message history
func (a *Atlas) ClearHistory() {
	if a.config.SystemPrompt != "" {
		a.messages = []Message{{Role: "system", Content: a.config.SystemPrompt}}
	} else {
		a.messages = nil
	}
}

// Destroy cleans up resources
func (a *Atlas) Destroy(ctx context.Context) error {
	if err := a.mcpManager.DisconnectAll(ctx); err != nil {
		return err
	}
	return a.providerRegistry.Destroy(ctx)
}

func (a *Atlas) getEnabledTools(toolNames []string) []tools.Tool {
	allTools := a.tools.List()

	// If specific tool names requested, filter to those
	if len(toolNames) > 0 {
		filtered := make([]tools.Tool, 0)
		toolSet := make(map[string]bool)
		for _, name := range toolNames {
			toolSet[name] = true
		}
		for _, t := range allTools {
			if toolSet[t.Name] {
				filtered = append(filtered, t)
			}
		}
		return filtered
	}

	// If talents are enabled, filter to allowed tools
	if len(a.enabledTalents) > 0 {
		allowedTools := make(map[string]bool)
		for talentName := range a.enabledTalents {
			if talentTools, ok := a.talentTools[talentName]; ok {
				for _, toolName := range talentTools {
					allowedTools[toolName] = true
				}
			}
		}
		if len(allowedTools) > 0 {
			filtered := make([]tools.Tool, 0)
			for _, t := range allTools {
				if allowedTools[t.Name] {
					filtered = append(filtered, t)
				}
			}
			return filtered
		}
	}

	return allTools
}

// EnableTalent enables a talent
func (a *Atlas) EnableTalent(name string) {
	a.enabledTalents[name] = true
}

// DisableTalent disables a talent
func (a *Atlas) DisableTalent(name string) {
	delete(a.enabledTalents, name)
}

// GetTalent returns a talent
func (a *Atlas) GetTalent(name string) (*talents.Talent, bool) {
	return a.talentLoader.Get(name)
}

// ListTalents returns all loaded talents
func (a *Atlas) ListTalents() []*talents.Talent {
	return a.talentLoader.List()
}

// LoadTalent loads a talent from a directory
func (a *Atlas) LoadTalent(path string) (*talents.Talent, error) {
	return a.talentLoader.LoadFromDirectory(path)
}

// ConnectMCP connects to an MCP server
func (a *Atlas) ConnectMCP(ctx context.Context, name string, transport MCPTransportConfig) error {
	_, err := a.mcpManager.Connect(ctx, name, mcp.TransportConfig{
		Type:    transport.Type,
		Command: transport.Command,
		Args:    transport.Args,
		Env:     transport.Env,
		URL:     transport.URL,
		Headers: transport.Headers,
	})
	return err
}

// DisconnectMCP disconnects from an MCP server
func (a *Atlas) DisconnectMCP(ctx context.Context, name string) error {
	return a.mcpManager.Disconnect(ctx, name)
}

// ListMCPServers returns connected MCP servers
func (a *Atlas) ListMCPServers() []string {
	return a.mcpManager.ListServers()
}

// CreateSubAgentRunner creates a SubAgentRunner for delegating tasks to specialized agents
func (a *Atlas) CreateSubAgentRunner() *subagent.Runner {
	if a.subAgentRunner == nil {
		a.subAgentRunner = subagent.NewRunner(&subagent.AtlasConfig{
			Provider:    a.config.Provider,
			Model:       a.config.Model,
			BaseURL:     a.config.BaseURL,
			APIKey:      a.config.APIKey,
			MaxSteps:    a.config.MaxSteps,
			Temperature: a.config.Temperature,
			MaxTokens:   a.config.MaxTokens,
		})
		// Register all current tools with the runner
		for _, tool := range a.tools.List() {
			_ = a.subAgentRunner.RegisterTool(tool)
		}
	}
	return a.subAgentRunner
}

// CreateSubAgent creates a subagent with the given configuration
func (a *Atlas) CreateSubAgent(name string, cfg subagent.Config) (*subagent.Config, error) {
	runner := a.CreateSubAgentRunner()
	agent := &subagent.Config{
		Name:         name,
		Type:         cfg.Type,
		SystemPrompt: cfg.SystemPrompt,
		Tools:        cfg.Tools,
		MaxTurns:     cfg.MaxTurns,
		Metadata:     cfg.Metadata,
	}
	if err := runner.RegisterAgent(agent); err != nil {
		return nil, err
	}
	return agent, nil
}

// ExecuteSubAgent executes a subagent with the given prompt
// The subagent runs in an isolated context (no parent conversation history)
func (a *Atlas) ExecuteSubAgent(ctx context.Context, agent *subagent.Config, opts subagent.ExecuteOptions) (*subagent.Result, error) {
	runner := a.CreateSubAgentRunner()
	return runner.Execute(ctx, agent, opts)
}

// ExecuteSubAgentsParallel executes multiple subagents in parallel
// Each subagent runs in its own isolated context
func (a *Atlas) ExecuteSubAgentsParallel(ctx context.Context, agents []*subagent.Config, opts subagent.ExecuteOptions) ([]*subagent.Result, error) {
	runner := a.CreateSubAgentRunner()
	return runner.ExecuteParallel(ctx, agents, opts)
}

// GetSubAgent returns a registered subagent by name
func (a *Atlas) GetSubAgent(name string) (*subagent.Config, bool) {
	if a.subAgentRunner == nil {
		return nil, false
	}
	return a.subAgentRunner.GetAgent(name)
}

// ListSubAgents returns all registered subagents
func (a *Atlas) ListSubAgents() []*subagent.Config {
	if a.subAgentRunner == nil {
		return nil
	}
	return a.subAgentRunner.ListAgents()
}
