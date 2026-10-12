// Package tools provides tool registration and execution
package tools

import (
	"context"
	"encoding/json"
	"fmt"
)

// Context provides context to tool handlers
type Context struct {
	ToolName string
	Atlas    interface{} // Reference to Atlas instance
}

// Handler is the function signature for tool handlers
type Handler func(ctx context.Context, args map[string]interface{}, toolCtx Context) (interface{}, error)

// Tool represents a callable tool
type Tool struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	InputSchema map[string]interface{} `json:"input_schema"`
	Handler     Handler                `json:"-"`
}

// Result is returned from tool execution
type Result struct {
	Success bool        `json:"success"`
	Data    interface{} `json:"data,omitempty"`
	Error   string      `json:"error,omitempty"`
}

// Registry manages tools
type Registry struct {
	tools map[string]Tool
}

// NewRegistry creates a new tool registry
func NewRegistry() *Registry {
	return &Registry{
		tools: make(map[string]Tool),
	}
}

// Register adds a tool to the registry
func (r *Registry) Register(tool Tool) error {
	if tool.Name == "" {
		return fmt.Errorf("tool name is required")
	}
	if tool.Handler == nil {
		return fmt.Errorf("tool handler is required")
	}
	if _, exists := r.tools[tool.Name]; exists {
		return fmt.Errorf("tool already registered: %s", tool.Name)
	}
	r.tools[tool.Name] = tool
	return nil
}

// RegisterMultiple registers multiple tools
func (r *Registry) RegisterMultiple(tools []Tool) error {
	for _, tool := range tools {
		if err := r.Register(tool); err != nil {
			return err
		}
	}
	return nil
}

// Get retrieves a tool by name
func (r *Registry) Get(name string) (Tool, bool) {
	tool, ok := r.tools[name]
	return tool, ok
}

// List returns all registered tools
func (r *Registry) List() []Tool {
	list := make([]Tool, 0, len(r.tools))
	for _, tool := range r.tools {
		list = append(list, tool)
	}
	return list
}

// ListNames returns names of all registered tools
func (r *Registry) ListNames() []string {
	names := make([]string, 0, len(r.tools))
	for name := range r.tools {
		names = append(names, name)
	}
	return names
}

// Execute runs a tool with the given arguments
func (r *Registry) Execute(ctx context.Context, name string, args map[string]interface{}, atlas interface{}) (Result, error) {
	tool, ok := r.tools[name]
	if !ok {
		return Result{Success: false, Error: fmt.Sprintf("tool not found: %s", name)}, nil
	}

	toolCtx := Context{
		ToolName: name,
		Atlas:    atlas,
	}

	data, err := tool.Handler(ctx, args, toolCtx)
	if err != nil {
		return Result{Success: false, Error: err.Error()}, nil
	}

	return Result{Success: true, Data: data}, nil
}

// Remove removes a tool from the registry
func (r *Registry) Remove(name string) {
	delete(r.tools, name)
}

// Clear removes all tools
func (r *Registry) Clear() {
	r.tools = make(map[string]Tool)
}

// ToProviderTools converts tools to provider format
func (r *Registry) ToProviderTools() []map[string]interface{} {
	result := make([]map[string]interface{}, 0, len(r.tools))
	for _, tool := range r.tools {
		result = append(result, map[string]interface{}{
			"type": "function",
			"function": map[string]interface{}{
				"name":        tool.Name,
				"description": tool.Description,
				"parameters":  tool.InputSchema,
			},
		})
	}
	return result
}

// ExecuteToolResult is returned from ExecuteJSON
type ExecuteToolResult struct {
	Success bool            `json:"success"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   string          `json:"error,omitempty"`
}

// ExecuteJSON executes a tool with JSON arguments
func (r *Registry) ExecuteJSON(ctx context.Context, name string, argsJSON []byte, atlas interface{}) ExecuteToolResult {
	var args map[string]interface{}
	if err := json.Unmarshal(argsJSON, &args); err != nil {
		return ExecuteToolResult{Success: false, Error: fmt.Sprintf("invalid JSON args: %v", err)}
	}

	result, err := r.Execute(ctx, name, args, atlas)
	if err != nil {
		return ExecuteToolResult{Success: false, Error: err.Error()}
	}

	resultJSON, _ := json.Marshal(result.Data)
	return ExecuteToolResult{
		Success: result.Success,
		Result:  resultJSON,
		Error:   result.Error,
	}
}
