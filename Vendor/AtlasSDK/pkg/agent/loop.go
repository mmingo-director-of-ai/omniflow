/**
 * Enhanced Agent Loop for Autonomous Execution (Go SDK)
 *
 * Features:
 * - Parallel tool execution for independent calls
 * - Configurable stop conditions
 * - Step-by-step state tracking
 * - Result aggregation and summarization
 */

package agent

import (
	"context"
	cryptorand "crypto/rand"
	"fmt"
	"sync"
	"time"
)

// StopCondition represents why execution stopped
type StopCondition string

const (
	StopConditionStop          StopCondition = "stop"           // No more tool calls
	StopConditionMaxSteps      StopCondition = "max_steps"      // Reached max steps
	StopConditionMaxTokens     StopCondition = "max_tokens"     // Reached token budget
	StopConditionMaxCost       StopCondition = "max_cost"       // Reached cost limit
	StopConditionTimeout       StopCondition = "timeout"        // Execution timeout
	StopConditionError         StopCondition = "error"          // Unrecoverable error
	StopConditionUserStop      StopCondition = "user_stop"      // User requested stop
	StopConditionGoalComplete  StopCondition = "goal_complete"  // Goal achieved
	StopConditionResourceLimit StopCondition = "resource_limit" // Hit resource limits
	StopConditionCustom        StopCondition = "custom"         // Custom condition met
)

// ToolExecution represents a tool execution result with metadata
type ToolExecution struct {
	ID        string                 `json:"id"`
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
	Result    interface{}            `json:"result"`
	Duration  time.Duration          `json:"duration"`
	Success   bool                   `json:"success"`
	Error     string                 `json:"error,omitempty"`
	Parallel  bool                   `json:"parallel"`
	Retries   int                    `json:"retries"`
}

// AgentStep represents a step in the agent loop
type AgentStep struct {
	Step       int             `json:"step"`
	Role       string          `json:"role"`
	Content    string          `json:"content"`
	ToolCalls  []ToolExecution `json:"toolCalls,omitempty"`
	Reasoning  string          `json:"reasoning,omitempty"`
	TokensUsed int             `json:"tokensUsed,omitempty"`
	Cost       float64         `json:"cost,omitempty"`
	Timestamp  time.Time       `json:"timestamp"`
}

// AgentState represents the agent loop state
type AgentState struct {
	Steps          []AgentStep     `json:"steps"`
	TotalTokens    int             `json:"totalTokens"`
	TotalCost      float64         `json:"totalCost"`
	TotalDuration  time.Duration   `json:"totalDuration"`
	ToolCalls      []ToolExecution `json:"toolCalls"`
	StopCondition  StopCondition   `json:"stopCondition"`
	CurrentGoal    string          `json:"currentGoal"`
	CompletedGoals []string        `json:"completedGoals"`
	PendingTools   []string        `json:"pendingTools"`
	Errors         []StepError     `json:"errors"`
}

// StepError represents an error during execution
type StepError struct {
	Step        int    `json:"step"`
	Error       string `json:"error"`
	Recoverable bool   `json:"recoverable"`
}

// AgentLoopConfig configures the agent loop
type AgentLoopConfig struct {
	MaxSteps          int            `json:"maxSteps"`
	MaxTokens         *int           `json:"maxTokens,omitempty"`
	MaxCost           *float64       `json:"maxCost,omitempty"`
	Timeout           *time.Duration `json:"timeout,omitempty"`
	Temperature       float64        `json:"temperature"`
	ParallelExecution bool           `json:"parallelExecution"`
	MaxParallelTools  int            `json:"maxParallelTools"`
	AutoRecovery      bool           `json:"autoRecovery"`
	MaxRetries        int            `json:"maxRetries"`
	OnStep            func(step AgentStep, state AgentState)
	OnToolCall        func(execution ToolExecution)
	OnStop            func(condition StopCondition, state AgentState)
	ShouldStop        func(state AgentState) StopCondition
}

// AgentResult represents the result of agent execution
type AgentResult struct {
	Text         string          `json:"text"`
	ToolCalls    []ToolExecution `json:"toolCalls"`
	FinishReason StopCondition   `json:"finishReason"`
	Steps        []AgentStep     `json:"steps"`
	State        AgentState      `json:"state"`
	Summary      string          `json:"summary"`
}

// Tool represents an executable tool
type Tool interface {
	Name() string
	Description() string
	Execute(ctx context.Context, args map[string]interface{}) (interface{}, error)
}

// SchemaProvider is an optional interface a Tool may implement to advertise
// its input parameter schema (JSON Schema as a map) to the model. Tools that
// do not implement it are still sent to the provider, but with no parameter
// schema. The agent loop type-asserts this in generateResponse; implementing
// it is how a tool tells the model what arguments it accepts.
type SchemaProvider interface {
	InputSchema() map[string]interface{}
}

// Provider represents an LLM provider
type Provider interface {
	Generate(ctx context.Context, messages []Message, tools []ToolSchema) (*GenerateResult, error)
}

// Message represents a chat message
type Message struct {
	Role string `json:"role"`
	// Content is the textual content of the message. For assistant
	// messages that issue tool calls, this carries the model's prose; for
	// tool messages it carries the serialized tool result.
	Content string `json:"content"`
	// ToolCallID links a tool-result message back to the assistant tool
	// call that produced it. Empty for user/assistant/system messages.
	ToolCallID string `json:"toolCallId,omitempty"`
}

// ToolSchema represents a tool definition
type ToolSchema struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	InputSchema map[string]interface{} `json:"inputSchema,omitempty"`
}

// GenerateResult represents a generation result
type GenerateResult struct {
	Content    string         `json:"content"`
	ToolCalls  []ToolCallData `json:"toolCalls,omitempty"`
	TokensUsed int            `json:"tokensUsed,omitempty"`
	Cost       float64        `json:"cost,omitempty"`
}

// ToolCallData represents a tool call from the provider
type ToolCallData struct {
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
	ID        string                 `json:"id,omitempty"`
}

// AgentLoop represents an enhanced agent loop
type AgentLoop struct {
	provider Provider
	tools    map[string]Tool
	config   AgentLoopConfig
	// mu guards all mutations of state. It lives on AgentLoop (not on
	// AgentState) so AgentState can be copied/snapshotted by value without
	// copying a lock (go vet "copies lock value").
	mu    sync.RWMutex
	state AgentState
}

// NewAgentLoop creates a new agent loop
func NewAgentLoop(provider Provider, tools map[string]Tool, config AgentLoopConfig) *AgentLoop {
	// Set defaults
	if config.MaxSteps == 0 {
		config.MaxSteps = 10
	}
	if config.Temperature == 0 {
		config.Temperature = 0.7
	}
	if config.MaxParallelTools == 0 {
		config.MaxParallelTools = 5
	}

	return &AgentLoop{
		provider: provider,
		tools:    tools,
		config:   config,
		state: AgentState{
			Steps:          make([]AgentStep, 0),
			ToolCalls:      make([]ToolExecution, 0),
			CompletedGoals: make([]string, 0),
			PendingTools:   make([]string, 0),
			Errors:         make([]StepError, 0),
		},
	}
}

// Execute runs the agent loop with the given prompt
func (a *AgentLoop) Execute(ctx context.Context, prompt string, messages []Message) (*AgentResult, error) {
	startTime := time.Now()
	a.resetState()

	a.mu.Lock()
	a.state.CurrentGoal = prompt
	a.mu.Unlock()

	conversation := make([]Message, 0, len(messages)+1)
	conversation = append(conversation, Message{Role: "user", Content: prompt})
	conversation = append(conversation, messages...)

	step := 0

Loop:
	for step < a.config.MaxSteps {
		step++

		// Check stop conditions
		if stopCond := a.checkStopConditions(startTime); stopCond != "" {
			a.mu.Lock()
			a.state.StopCondition = stopCond
			a.mu.Unlock()
			break Loop
		}

		// Check context cancellation. A bare `break` here would only exit
		// the select and fall through to generateResponse on a cancelled
		// ctx; break the for loop explicitly via the label.
		select {
		case <-ctx.Done():
			a.mu.Lock()
			a.state.StopCondition = StopConditionUserStop
			a.mu.Unlock()
			break Loop
		default:
		}

		// Generate response
		response, err := a.generateResponse(ctx, conversation)
		if err != nil {
			a.mu.Lock()
			a.state.StopCondition = StopConditionError
			a.mu.Unlock()
			return nil, fmt.Errorf("provider error: %w", err)
		}

		// Track tokens and cost
		a.mu.Lock()
		a.state.TotalTokens += response.TokensUsed
		a.state.TotalCost += response.Cost
		a.mu.Unlock()

		// Create assistant step
		assistantStep := AgentStep{
			Step:       step,
			Role:       "assistant",
			Content:    response.Content,
			ToolCalls:  make([]ToolExecution, 0),
			TokensUsed: response.TokensUsed,
			Cost:       response.Cost,
			Timestamp:  time.Now(),
		}

		// If no tool calls, we're done
		if len(response.ToolCalls) == 0 {
			a.mu.Lock()
			a.state.Steps = append(a.state.Steps, assistantStep)
			a.state.StopCondition = StopConditionStop
			a.mu.Unlock()
			break Loop
		}

		// Execute tool calls
		executions := a.executeToolCalls(ctx, response.ToolCalls, step)
		assistantStep.ToolCalls = executions

		// Append ONE assistant message carrying its content and the tool
		// calls it issued, then one `tool` message per execution keyed by
		// its tool-call id. Re-appending the assistant content per tool
		// call bloats context and produces malformed multi-tool history
		// that some providers reject.
		conversation = append(conversation, Message{
			Role:    "assistant",
			Content: response.Content,
		})
		for _, exec := range executions {
			conversation = append(conversation, Message{
				Role:       "tool",
				Content:    fmt.Sprintf("%v", exec.Result),
				ToolCallID: exec.ID,
			})
		}

		a.mu.Lock()
		a.state.Steps = append(a.state.Steps, assistantStep)
		a.state.ToolCalls = append(a.state.ToolCalls, executions...)
		a.mu.Unlock()

		// Callback for step (snapshot taken without holding a.mu)
		if a.config.OnStep != nil {
			a.config.OnStep(assistantStep, a.getState())
		}
	}

	a.mu.Lock()
	// Set final stop condition if not set
	if a.state.StopCondition == "" {
		a.state.StopCondition = StopConditionMaxSteps
	}
	a.state.TotalDuration = time.Since(startTime)
	stopCond := a.state.StopCondition
	a.mu.Unlock()

	// Callback for stop (snapshot taken without holding a.mu)
	if a.config.OnStop != nil {
		a.config.OnStop(stopCond, a.getState())
	}

	result := &AgentResult{
		Text:         a.getLastContent(),
		ToolCalls:    a.getToolCalls(),
		FinishReason: stopCond,
		Steps:        a.getSteps(),
		State:        a.getState(),
		Summary:      a.generateSummary(),
	}

	return result, nil
}

// generateResponse generates a response from the provider
func (a *AgentLoop) generateResponse(ctx context.Context, messages []Message) (*GenerateResult, error) {
	toolSchemas := make([]ToolSchema, 0, len(a.tools))
	for _, tool := range a.tools {
		schema := ToolSchema{
			Name:        tool.Name(),
			Description: tool.Description(),
		}
		// Populate the input schema if the tool advertises one via the
		// optional SchemaProvider interface. Without this the model gets
		// no parameter definitions and refuses or hallucinates arguments.
		if sp, ok := tool.(SchemaProvider); ok {
			schema.InputSchema = sp.InputSchema()
		}
		toolSchemas = append(toolSchemas, schema)
	}

	return a.provider.Generate(ctx, messages, toolSchemas)
}

// executeToolCalls executes tool calls, potentially in parallel
func (a *AgentLoop) executeToolCalls(ctx context.Context, toolCalls []ToolCallData, step int) []ToolExecution {
	executions := make([]ToolExecution, 0, len(toolCalls))

	// Analyze dependencies
	independent, dependent := a.analyzeDependencies(toolCalls)

	// Execute independent tools in parallel if enabled
	if a.config.ParallelExecution && len(independent) > 1 {
		parallel := a.executeParallelTools(ctx, independent, step)
		executions = append(executions, parallel...)
	} else {
		// Execute all sequentially
		for _, tc := range independent {
			exec := a.executeTool(ctx, tc.Name, tc.Arguments, tc.ID, step, false)
			executions = append(executions, exec)
		}
	}

	// Execute dependent tools sequentially
	for _, tc := range dependent {
		exec := a.executeTool(ctx, tc.Name, tc.Arguments, tc.ID, step, false)
		executions = append(executions, exec)
	}

	return executions
}

// analyzeDependencies determines which tools can run in parallel
func (a *AgentLoop) analyzeDependencies(toolCalls []ToolCallData) (independent []ToolCallData, dependent []ToolCallData) {
	readOperations := []string{"get", "read", "list", "search", "query", "fetch", "find", "show"}

	for _, tc := range toolCalls {
		isRead := false
		toolName := tc.Name
		for _, op := range readOperations {
			if contains(toolName, op) {
				isRead = true
				break
			}
		}

		if isRead {
			independent = append(independent, tc)
		} else {
			dependent = append(dependent, tc)
		}
	}

	return independent, dependent
}

// executeParallelTools executes ALL tools concurrently, bounding the number
// of simultaneous executions to MaxParallelTools via a semaphore. Results are
// written into a pre-sized slice by index so emission order is preserved
// (callers pair them positionally / by id). Never truncate-and-drop calls.
func (a *AgentLoop) executeParallelTools(ctx context.Context, tools []ToolCallData, step int) []ToolExecution {
	executions := make([]ToolExecution, len(tools))

	// Bound concurrency. Guard against a non-positive limit (a size-0
	// buffered channel would deadlock) for callers that bypass NewAgentLoop.
	maxParallel := a.config.MaxParallelTools
	if maxParallel <= 0 {
		maxParallel = len(tools)
	}
	sem := make(chan struct{}, maxParallel)

	var wg sync.WaitGroup
	for i, tc := range tools {
		wg.Add(1)
		go func(i int, tc ToolCallData) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			executions[i] = a.executeTool(ctx, tc.Name, tc.Arguments, tc.ID, step, true)
		}(i, tc)
	}

	wg.Wait()
	return executions
}

// executeTool executes a single tool with retries
func (a *AgentLoop) executeTool(ctx context.Context, name string, args map[string]interface{}, id string, step int, parallel bool) ToolExecution {
	toolID := id
	if toolID == "" {
		toolID = fmt.Sprintf("call_%d_%s", time.Now().UnixNano(), randomString(9))
	}

	startTime := time.Now()
	retries := 0
	var lastError string

	tool, ok := a.tools[name]
	if !ok {
		return ToolExecution{
			ID:        toolID,
			Name:      name,
			Arguments: args,
			Result:    map[string]interface{}{"error": fmt.Sprintf("Unknown tool: %s", name)},
			Duration:  time.Since(startTime),
			Success:   false,
			Error:     fmt.Sprintf("Unknown tool: %s", name),
			Parallel:  parallel,
			Retries:   0,
		}
	}

	maxRetries := a.config.MaxRetries
	if maxRetries == 0 {
		maxRetries = 3
	}

	for retries <= maxRetries {
		// Stop retrying if the caller's context was cancelled.
		if err := ctx.Err(); err != nil {
			lastError = err.Error()
			a.recordError(step, lastError, false)
			break
		}

		// Thread the caller's ctx so cancellation/timeout reaches the tool.
		result, err := tool.Execute(ctx, args)
		if err == nil {
			exec := ToolExecution{
				ID:        toolID,
				Name:      name,
				Arguments: args,
				Result:    result,
				Duration:  time.Since(startTime),
				Success:   true,
				Parallel:  parallel,
				Retries:   retries,
			}

			if a.config.OnToolCall != nil {
				a.config.OnToolCall(exec)
			}

			return exec
		}

		retries++
		lastError = err.Error()

		// Record error
		a.recordError(step, lastError, retries <= maxRetries)

		if retries <= maxRetries {
			// Exponential backoff, interruptible by ctx so a cancelled
			// agent stops sleeping immediately.
			backoff := time.Duration(min(1000*intPow(2, retries), 10000)) * time.Millisecond
			select {
			case <-ctx.Done():
				lastError = ctx.Err().Error()
				a.recordError(step, lastError, false)
				retries = maxRetries + 1 // force loop exit
			case <-time.After(backoff):
			}
		}
	}

	return ToolExecution{
		ID:        toolID,
		Name:      name,
		Arguments: args,
		Result:    map[string]interface{}{"error": lastError},
		Duration:  time.Since(startTime),
		Success:   false,
		Error:     lastError,
		Parallel:  parallel,
		Retries:   retries,
	}
}

// checkStopConditions checks all stop conditions
func (a *AgentLoop) checkStopConditions(startTime time.Time) StopCondition {
	// Timeout check
	if a.config.Timeout != nil {
		if time.Since(startTime) > *a.config.Timeout {
			return StopConditionTimeout
		}
	}

	a.mu.RLock()
	totalTokens := a.state.TotalTokens
	totalCost := a.state.TotalCost
	recentErrors := 0
	for _, e := range a.state.Errors {
		if !e.Recoverable {
			recentErrors++
		}
	}
	a.mu.RUnlock()

	// Token budget check
	if a.config.MaxTokens != nil {
		if totalTokens >= *a.config.MaxTokens {
			return StopConditionMaxTokens
		}
	}

	// Cost check
	if a.config.MaxCost != nil {
		if totalCost >= *a.config.MaxCost {
			return StopConditionMaxCost
		}
	}

	// Too many errors
	if recentErrors >= 3 {
		return StopConditionError
	}

	// Custom stop condition (snapshot taken without holding a.mu)
	if a.config.ShouldStop != nil {
		if cond := a.config.ShouldStop(a.getState()); cond != "" {
			return cond
		}
	}

	return ""
}

// recordError appends an error to the agent state under lock.
func (a *AgentLoop) recordError(step int, msg string, recoverable bool) {
	a.mu.Lock()
	a.state.Errors = append(a.state.Errors, StepError{
		Step:        step,
		Error:       msg,
		Recoverable: recoverable,
	})
	a.mu.Unlock()
}

// generateSummary creates a summary of execution
func (a *AgentLoop) generateSummary() string {
	a.mu.RLock()
	numSteps := len(a.state.Steps)
	numToolCalls := len(a.state.ToolCalls)
	totalTokens := a.state.TotalTokens
	totalCost := a.state.TotalCost
	numErrors := len(a.state.Errors)
	stopCond := a.state.StopCondition
	a.mu.RUnlock()

	parts := make([]string, 0)

	parts = append(parts, fmt.Sprintf("Completed in %d steps", numSteps))
	parts = append(parts, fmt.Sprintf("with %d tool calls", numToolCalls))

	if totalTokens > 0 {
		parts = append(parts, fmt.Sprintf("%d tokens used", totalTokens))
	}

	if totalCost > 0 {
		parts = append(parts, fmt.Sprintf("$%.4f cost", totalCost))
	}

	if numErrors > 0 {
		parts = append(parts, fmt.Sprintf("%d errors encountered", numErrors))
	}

	parts = append(parts, fmt.Sprintf("stopped due to %s", stopCond))

	return join(parts, ", ")
}

// getState returns a deep, mutex-free snapshot of the current state. The
// returned AgentState shares no slice backing arrays with the live state, so
// callbacks may read it freely while the loop keeps appending.
func (a *AgentLoop) getState() AgentState {
	a.mu.RLock()
	defer a.mu.RUnlock()

	snapshot := a.state // value copy of scalars
	snapshot.Steps = a.getStepsLocked()
	snapshot.ToolCalls = cloneToolExecutions(a.state.ToolCalls)
	snapshot.CompletedGoals = cloneStrings(a.state.CompletedGoals)
	snapshot.PendingTools = cloneStrings(a.state.PendingTools)
	snapshot.Errors = cloneStepErrors(a.state.Errors)
	return snapshot
}

// getSteps returns a deep copy of the recorded steps.
func (a *AgentLoop) getSteps() []AgentStep {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.getStepsLocked()
}

// getStepsLocked deep-copies steps; caller must hold a.mu.
func (a *AgentLoop) getStepsLocked() []AgentStep {
	steps := make([]AgentStep, len(a.state.Steps))
	for i, s := range a.state.Steps {
		s.ToolCalls = cloneToolExecutions(s.ToolCalls)
		steps[i] = s
	}
	return steps
}

// getToolCalls returns a deep copy of all recorded tool executions.
func (a *AgentLoop) getToolCalls() []ToolExecution {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return cloneToolExecutions(a.state.ToolCalls)
}

// resetState resets the agent state
func (a *AgentLoop) resetState() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.state = AgentState{
		Steps:          make([]AgentStep, 0),
		ToolCalls:      make([]ToolExecution, 0),
		CompletedGoals: make([]string, 0),
		PendingTools:   make([]string, 0),
		Errors:         make([]StepError, 0),
	}
}

// getLastContent gets the content from the last step
func (a *AgentLoop) getLastContent() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if len(a.state.Steps) == 0 {
		return ""
	}
	return a.state.Steps[len(a.state.Steps)-1].Content
}

// cloneToolExecutions returns a shallow-per-element copy of tool executions.
func cloneToolExecutions(in []ToolExecution) []ToolExecution {
	if in == nil {
		return nil
	}
	out := make([]ToolExecution, len(in))
	copy(out, in)
	return out
}

// cloneStepErrors returns a copy of the step errors slice.
func cloneStepErrors(in []StepError) []StepError {
	if in == nil {
		return nil
	}
	out := make([]StepError, len(in))
	copy(out, in)
	return out
}

// cloneStrings returns a copy of a string slice.
func cloneStrings(in []string) []string {
	if in == nil {
		return nil
	}
	out := make([]string, len(in))
	copy(out, in)
	return out
}

// Helper functions

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsSubstring(s, substr))
}

func containsSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func intPow(base, exp int) int {
	result := 1
	for i := 0; i < exp; i++ {
		result *= base
	}
	return result
}

func randomString(n int) string {
	const letters = "abcdefghijklmnopqrstuvwxyz0123456789"
	if n <= 0 {
		return ""
	}
	// Draw each byte independently from crypto/rand so IDs generated in a
	// tight loop don't collide (time.Now().UnixNano() barely advances and
	// produced near-constant strings).
	raw := make([]byte, n)
	if _, err := cryptorand.Read(raw); err != nil {
		// Fall back to a time-seeded value; still unique enough for IDs
		// and only reached if the system CSPRNG is unavailable.
		seed := time.Now().UnixNano()
		for i := range raw {
			seed = seed*1103515245 + 12345
			raw[i] = byte(seed >> 16)
		}
	}
	for i := range raw {
		raw[i] = letters[int(raw[i])%len(letters)]
	}
	return string(raw)
}

func join(s []string, sep string) string {
	result := ""
	for i, str := range s {
		if i > 0 {
			result += sep
		}
		result += str
	}
	return result
}
