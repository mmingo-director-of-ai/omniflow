// Package subagent provides subagent delegation functionality for Atlas SDK
package subagent

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/tools"
)

// SubAgentType defines the specialization of a subagent
type SubAgentType string

const (
	// SubAgentTypeExplore focuses on research and analysis
	SubAgentTypeExplore SubAgentType = "explore"
	// SubAgentTypeGeneral is a general-purpose agent
	SubAgentTypeGeneral SubAgentType = "general"
	// SubAgentTypePlan focuses on planning and strategy
	SubAgentTypePlan SubAgentType = "plan"
)

// MaxSubAgents is the maximum number of parallel subagents allowed
const MaxSubAgents = 10

// Default system prompts by agent type
var defaultPrompts = map[SubAgentType]string{
	SubAgentTypeExplore: "You are an exploration subagent. Research and analyze information thoroughly. Focus on discovering relevant information and connections.",
	SubAgentTypeGeneral: "You are a general-purpose subagent. Complete the given task to the best of your ability.",
	SubAgentTypePlan:    "You are a planning subagent. Analyze requirements and create actionable plans. Break down complex tasks into clear steps.",
}

// Config represents a subagent configuration
type Config struct {
	// Name is the unique identifier for this subagent
	Name string `json:"name"`
	// Type determines the default behavior and prompts
	Type SubAgentType `json:"type"`
	// SystemPrompt overrides the default prompt for the type
	SystemPrompt string `json:"systemPrompt,omitempty"`
	// Tools is a filtered list of tool names this agent can use
	Tools []string `json:"tools,omitempty"`
	// MaxTurns is the maximum number of iterations (default: 10)
	MaxTurns int `json:"maxTurns,omitempty"`
	// Metadata contains additional custom data
	Metadata map[string]string `json:"metadata,omitempty"`
}

// Message represents a chat message for subagent execution
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ExecutionResult represents the result of subagent execution
type ExecutionResult struct {
	Text         string     `json:"text"`
	ToolCalls    []ToolCall `json:"toolCalls,omitempty"`
	FinishReason string     `json:"finishReason"`
	Steps        []Step     `json:"steps"`
}

// ToolCall represents a tool call in execution
type ToolCall struct {
	ID        string                 `json:"id,omitempty"`
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
}

// Step represents a single step in execution
type Step struct {
	Step     int                    `json:"step"`
	Role     string                 `json:"role"`
	Content  string                 `json:"content"`
	ToolName string                 `json:"toolName,omitempty"`
	ToolArgs map[string]interface{} `json:"toolArgs,omitempty"`
}

// Result represents the outcome of a subagent execution
type Result struct {
	// AgentName is the name of the agent that produced this result
	AgentName string `json:"agentName"`
	// Output is the text output from the agent
	Output string `json:"output"`
	// Success indicates whether execution completed successfully
	Success bool `json:"success"`
	// Error contains the error message if failed
	Error string `json:"error,omitempty"`
	// Turns is the number of turns executed
	Turns int `json:"turns"`
	// ExecutionResult contains the full execution details
	ExecutionResult *ExecutionResult `json:"executionResult,omitempty"`
}

// Callbacks provides hooks for subagent execution events
type Callbacks struct {
	// OnStart is called when an agent starts execution
	OnStart func(agentName string)
	// OnToolCall is called when an agent makes a tool call
	OnToolCall func(agentName string, toolName string, args map[string]interface{})
	// OnComplete is called when an agent completes execution
	OnComplete func(agentName string, result Result)
}

// ExecuteOptions configures subagent execution
type ExecuteOptions struct {
	// Prompt is the task for the subagent
	Prompt string
	// Callbacks for progress events
	Callbacks *Callbacks
	// Context data to pass to the agent
	Context map[string]interface{}
}

// AtlasConfig represents Atlas configuration for subagent instantiation
type AtlasConfig struct {
	Provider     string
	Model        string
	BaseURL      string
	APIKey       string
	MaxSteps     int
	Temperature  float64
	MaxTokens    int
	SystemPrompt string
}

// AtlasExecutor is the interface for Atlas instances used by subagents
type AtlasExecutor interface {
	Initialize(ctx context.Context) error
	RegisterTool(tool tools.Tool) error
	RegisterTools(toolsList []tools.Tool) error
	Execute(ctx context.Context, messages []Message, onToolCall func(tool string, args map[string]interface{})) (*ExecutionResult, error)
	Destroy(ctx context.Context) error
}

// AtlasFactory creates Atlas instances for subagent execution
type AtlasFactory func(config *AtlasConfig) (AtlasExecutor, error)

// Runner manages and executes subagents with isolated contexts
type Runner struct {
	config       *AtlasConfig
	agents       map[string]*Config
	tools        *tools.Registry
	mu           sync.RWMutex
	maxParallel  int
	atlasFactory AtlasFactory
}

// NewRunner creates a new subagent runner
func NewRunner(config *AtlasConfig) *Runner {
	return &Runner{
		config:       config,
		agents:       make(map[string]*Config),
		tools:        tools.NewRegistry(),
		maxParallel:  MaxSubAgents,
		atlasFactory: nil, // Must be set via SetAtlasFactory
	}
}

// SetAtlasFactory sets a custom factory for creating Atlas instances
func (r *Runner) SetAtlasFactory(factory AtlasFactory) {
	r.atlasFactory = factory
}

// RegisterTool registers a tool for subagents to use
func (r *Runner) RegisterTool(tool tools.Tool) error {
	return r.tools.Register(tool)
}

// RegisterTools registers multiple tools
func (r *Runner) RegisterTools(toolsList []tools.Tool) error {
	return r.tools.RegisterMultiple(toolsList)
}

// GetTools returns all registered tools
func (r *Runner) GetTools() []tools.Tool {
	return r.tools.List()
}

// RegisterAgent registers a subagent configuration
func (r *Runner) RegisterAgent(agent *Config) error {
	if agent.Name == "" {
		return fmt.Errorf("subagent name is required")
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	if agent.MaxTurns == 0 {
		agent.MaxTurns = 10
	}

	r.agents[agent.Name] = agent
	return nil
}

// GetAgent returns a subagent by name
func (r *Runner) GetAgent(name string) (*Config, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	agent, ok := r.agents[name]
	return agent, ok
}

// ListAgents returns all registered subagents
func (r *Runner) ListAgents() []*Config {
	r.mu.RLock()
	defer r.mu.RUnlock()

	agents := make([]*Config, 0, len(r.agents))
	for _, agent := range r.agents {
		agents = append(agents, agent)
	}
	return agents
}

// RemoveAgent removes a subagent by name
func (r *Runner) RemoveAgent(name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.agents[name]; ok {
		delete(r.agents, name)
		return true
	}
	return false
}

// buildSystemPrompt builds the system prompt for a subagent
func (r *Runner) buildSystemPrompt(agent *Config) string {
	if agent.SystemPrompt != "" {
		return agent.SystemPrompt
	}
	if prompt, ok := defaultPrompts[agent.Type]; ok {
		return prompt
	}
	return defaultPrompts[SubAgentTypeGeneral]
}

// Execute runs a single subagent with the given prompt
func (r *Runner) Execute(ctx context.Context, agent *Config, opts ExecuteOptions) (*Result, error) {
	if agent == nil {
		return nil, fmt.Errorf("subagent is nil")
	}

	if r.atlasFactory == nil {
		return nil, fmt.Errorf("atlas factory not set, call SetAtlasFactory first")
	}

	if opts.Callbacks != nil && opts.Callbacks.OnStart != nil {
		opts.Callbacks.OnStart(agent.Name)
	}

	maxTurns := agent.MaxTurns
	if maxTurns == 0 {
		maxTurns = 10
	}

	// Create isolated Atlas instance for this subagent
	atlasConfig := &AtlasConfig{
		Provider:     r.config.Provider,
		Model:        r.config.Model,
		BaseURL:      r.config.BaseURL,
		APIKey:       r.config.APIKey,
		SystemPrompt: r.buildSystemPrompt(agent),
		MaxSteps:     maxTurns,
		Temperature:  r.config.Temperature,
		MaxTokens:    r.config.MaxTokens,
	}

	executor, err := r.atlasFactory(atlasConfig)
	if err != nil {
		return &Result{
			AgentName: agent.Name,
			Success:   false,
			Error:     fmt.Sprintf("failed to create atlas instance: %v", err),
			Turns:     0,
		}, err
	}

	if err := executor.Initialize(ctx); err != nil {
		return &Result{
			AgentName: agent.Name,
			Success:   false,
			Error:     fmt.Sprintf("failed to initialize atlas: %v", err),
			Turns:     0,
		}, err
	}

	// Register filtered tools
	allTools := r.GetTools()
	filteredTools := allTools
	if len(agent.Tools) > 0 {
		toolSet := make(map[string]bool)
		for _, name := range agent.Tools {
			toolSet[name] = true
		}
		filteredTools = make([]tools.Tool, 0)
		for _, t := range allTools {
			if toolSet[t.Name] {
				filteredTools = append(filteredTools, t)
			}
		}
	}
	if err := executor.RegisterTools(filteredTools); err != nil {
		_ = executor.Destroy(ctx)
		return &Result{
			AgentName: agent.Name,
			Success:   false,
			Error:     fmt.Sprintf("failed to register tools: %v", err),
			Turns:     0,
		}, err
	}

	// Build initial message with optional context
	userPrompt := opts.Prompt
	if len(opts.Context) > 0 {
		contextJSON, _ := json.MarshalIndent(opts.Context, "", "  ")
		userPrompt = fmt.Sprintf("Context:\n%s\n\nTask:\n%s", string(contextJSON), opts.Prompt)
	}

	// Execute with isolated context
	result, err := executor.Execute(ctx, []Message{
		{Role: "user", Content: userPrompt},
	}, func(tool string, args map[string]interface{}) {
		if opts.Callbacks != nil && opts.Callbacks.OnToolCall != nil {
			opts.Callbacks.OnToolCall(agent.Name, tool, args)
		}
	})

	if err != nil {
		_ = executor.Destroy(ctx)
		subAgentResult := &Result{
			AgentName: agent.Name,
			Success:   false,
			Error:     err.Error(),
			Turns:     0,
		}
		if opts.Callbacks != nil && opts.Callbacks.OnComplete != nil {
			opts.Callbacks.OnComplete(agent.Name, *subAgentResult)
		}
		return subAgentResult, err
	}

	_ = executor.Destroy(ctx)

	subAgentResult := &Result{
		AgentName:       agent.Name,
		Output:          result.Text,
		Success:         true,
		Turns:           len(result.Steps),
		ExecutionResult: result,
	}

	if opts.Callbacks != nil && opts.Callbacks.OnComplete != nil {
		opts.Callbacks.OnComplete(agent.Name, *subAgentResult)
	}

	return subAgentResult, nil
}

// ExecuteParallel runs multiple subagents in parallel
func (r *Runner) ExecuteParallel(ctx context.Context, agents []*Config, opts ExecuteOptions) ([]*Result, error) {
	if len(agents) > r.maxParallel {
		return nil, fmt.Errorf("too many subagents: maximum is %d", r.maxParallel)
	}
	if len(agents) == 0 {
		return nil, fmt.Errorf("no subagents provided")
	}

	var wg sync.WaitGroup
	results := make([]*Result, len(agents))
	errors := make([]error, len(agents))

	for i, agent := range agents {
		wg.Add(1)
		go func(idx int, ag *Config) {
			defer wg.Done()
			result, err := r.Execute(ctx, ag, opts)
			results[idx] = result
			errors[idx] = err
		}(i, agent)
	}

	wg.Wait()

	for i, err := range errors {
		if err != nil {
			return results, fmt.Errorf("subagent %s failed: %w", agents[i].Name, err)
		}
	}

	return results, nil
}

// ToJSON serializes the runner's agents to JSON
func (r *Runner) ToJSON() ([]byte, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	return json.MarshalIndent(map[string]interface{}{"agents": r.agents}, "", "  ")
}

// FromJSON loads agents from JSON
func (r *Runner) FromJSON(data []byte) error {
	var wrapper struct {
		Agents map[string]*Config `json:"agents"`
	}
	if err := json.Unmarshal(data, &wrapper); err != nil {
		return fmt.Errorf("failed to parse agents JSON: %w", err)
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	for name, agent := range wrapper.Agents {
		agent.Name = name
		r.agents[name] = agent
	}
	return nil
}

// CreateExploreAgent creates a pre-configured exploration subagent
func CreateExploreAgent(name, systemPrompt string) *Config {
	if systemPrompt == "" {
		systemPrompt = defaultPrompts[SubAgentTypeExplore]
	}
	return &Config{
		Name:         name,
		Type:         SubAgentTypeExplore,
		SystemPrompt: systemPrompt,
		MaxTurns:     10,
	}
}

// CreatePlanAgent creates a pre-configured planning subagent
func CreatePlanAgent(name, systemPrompt string) *Config {
	if systemPrompt == "" {
		systemPrompt = defaultPrompts[SubAgentTypePlan]
	}
	return &Config{
		Name:         name,
		Type:         SubAgentTypePlan,
		SystemPrompt: systemPrompt,
		MaxTurns:     10,
	}
}

// CreateGeneralAgent creates a pre-configured general-purpose subagent
func CreateGeneralAgent(name, systemPrompt string) *Config {
	if systemPrompt == "" {
		systemPrompt = defaultPrompts[SubAgentTypeGeneral]
	}
	return &Config{
		Name:         name,
		Type:         SubAgentTypeGeneral,
		SystemPrompt: systemPrompt,
		MaxTurns:     10,
	}
}

// Legacy type aliases for backwards compatibility
type (
	// SubAgentConfig is an alias for Config (backwards compatibility)
	SubAgentConfig = Config
	// SubAgentResult is an alias for Result (backwards compatibility)
	SubAgentResult = Result
	// SubAgentCallbacks is an alias for Callbacks (backwards compatibility)
	SubAgentCallbacks = Callbacks
	// SubAgentExecuteOptions is an alias for ExecuteOptions (backwards compatibility)
	SubAgentExecuteOptions = ExecuteOptions
)

// SubAgentRunner is an alias for Runner (backwards compatibility)
type SubAgentRunner = Runner

// NewSubAgentRunner creates a new subagent runner (backwards compatibility)
func NewSubAgentRunner(config *AtlasConfig) *Runner {
	return NewRunner(config)
}
