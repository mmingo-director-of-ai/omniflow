// Package capabilities loads skills & plugins from any frontier provider format
// and normalizes them into tools (callable) + instructions (prompt guidance)
// that the bootstrap layer and agent loop already consume.
//
// Supported formats (pluggable adapters): Anthropic Agent Skills (SKILL.md),
// OpenAI plugins (ai-plugin.json + OpenAPI), Claude Code plugins (plugin.json),
// and raw function-tool definitions (OpenAI/Anthropic). MCP is handled by the
// existing bridge; an MCP server reference here is surfaced for it to connect.
package capabilities

import "gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"

// CapabilityFormat identifies which frontier format a capability came from.
type CapabilityFormat string

const (
	FormatAnthropicSkill CapabilityFormat = "anthropic-skill"
	FormatOpenAIPlugin   CapabilityFormat = "openai-plugin"
	FormatClaudePlugin   CapabilityFormat = "claude-plugin"
	FormatFunctionTools  CapabilityFormat = "function-tools"
	FormatMCP            CapabilityFormat = "mcp"
)

// InvocationKind identifies how a normalized tool is actually invoked once the
// model calls it.
type InvocationKind string

const (
	InvocationOpenAPI  InvocationKind = "openapi"
	InvocationFunction InvocationKind = "function"
	InvocationMCP      InvocationKind = "mcp"
	InvocationScript   InvocationKind = "script"
)

// ParamRef records the name and location ("path"/"query"/"header") of an
// OpenAPI parameter so the invocation layer knows where to place each argument.
// This is additive relative to the TS ToolInvocation, which did not retain
// per-parameter location metadata.
type ParamRef struct {
	Name string `json:"name"`
	In   string `json:"in"`
}

// ToolInvocation describes how a normalized tool is dispatched. The Kind field
// selects which set of fields is meaningful:
//
//   - openapi:  Method, Path, BaseURL, Security, Params, BodyKeys
//   - function: (no extra fields)
//   - mcp:      Server
//   - script:   ScriptPath
type ToolInvocation struct {
	Kind InvocationKind `json:"kind"`

	// openapi fields
	Method   string     `json:"method,omitempty"`
	Path     string     `json:"path,omitempty"`
	BaseURL  string     `json:"baseUrl,omitempty"`
	Security []string   `json:"security,omitempty"`
	Params   []ParamRef `json:"params,omitempty"`
	BodyKeys []string   `json:"bodyKeys,omitempty"`

	// mcp field
	Server string `json:"server,omitempty"`

	// script field. Tagged "scriptPath" rather than "path" because Go forbids
	// two fields sharing one JSON tag; the OpenAPI Path field already owns
	// "path", and the two are mutually exclusive by Kind.
	ScriptPath string `json:"scriptPath,omitempty"`
}

// CapabilityTool is a normalized callable tool — shape-compatible with the
// agent loop's tool list.
type CapabilityTool struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	// InputSchema is a JSON Schema (object). Canonical field name matches
	// the rest of Atlas.
	InputSchema map[string]interface{} `json:"inputSchema"`
	// Source is the adapter/source id this tool came from.
	Source     string          `json:"source"`
	Invocation *ToolInvocation `json:"invocation,omitempty"`
}

// MCPServerRef is an MCP server referenced by a capability, for the bridge to
// connect.
type MCPServerRef struct {
	Name      string      `json:"name"`
	Transport interface{} `json:"transport,omitempty"`
}

// LoadedCapability is the normalized result of loading one skill/plugin.
type LoadedCapability struct {
	Name        string           `json:"name"`
	Description string           `json:"description"`
	Format      CapabilityFormat `json:"format"`
	// Instructions are injected into the system prompt (skill guidance).
	Instructions string           `json:"instructions,omitempty"`
	Tools        []CapabilityTool `json:"tools"`
	// MCPServers are MCP servers referenced by the capability, for the
	// bridge to connect.
	MCPServers []MCPServerRef `json:"mcpServers,omitempty"`
	// Meta holds original metadata, for callers that need it (auth,
	// versions, etc.).
	Meta map[string]interface{} `json:"meta,omitempty"`
}

// ToToolSchema converts a normalized capability tool into the agent loop's
// ToolSchema so it composes with the Go bootstrap/loop.
func (t CapabilityTool) ToToolSchema() agent.ToolSchema {
	return agent.ToolSchema{
		Name:        t.Name,
		Description: t.Description,
		InputSchema: t.InputSchema,
	}
}
