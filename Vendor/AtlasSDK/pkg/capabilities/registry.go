// Registry that aggregates loaded capabilities and composes them for the agent.
package capabilities

import (
	"strings"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

// CapabilityFormatError is returned when an input cannot be recognized as a
// supported capability format.
type CapabilityFormatError struct {
	Message string
}

func (e *CapabilityFormatError) Error() string {
	return e.Message
}

// CapabilityRegistry aggregates loaded capabilities and composes them into the
// system prompt + tool list the agent loop consumes.
type CapabilityRegistry struct {
	caps []LoadedCapability
}

// NewCapabilityRegistry returns an empty registry.
func NewCapabilityRegistry() *CapabilityRegistry {
	return &CapabilityRegistry{caps: []LoadedCapability{}}
}

// Add appends an already-loaded capability and returns the registry for
// chaining.
func (r *CapabilityRegistry) Add(cap LoadedCapability) *CapabilityRegistry {
	r.caps = append(r.caps, cap)
	return r
}

// Load sniffs the input's format, loads it, and adds it. It returns an error
// when the format is unrecognized (and leaves the registry unchanged in that
// case).
func (r *CapabilityRegistry) Load(input interface{}) (*CapabilityRegistry, error) {
	cap, err := LoadCapability(input)
	if err != nil {
		return r, err
	}
	return r.Add(cap), nil
}

// List returns a copy of the loaded capabilities.
func (r *CapabilityRegistry) List() []LoadedCapability {
	out := make([]LoadedCapability, len(r.caps))
	copy(out, r.caps)
	return out
}

// GetTools returns all callable tools across capabilities, de-duplicated by
// name (first wins).
func (r *CapabilityRegistry) GetTools() []CapabilityTool {
	seen := map[string]struct{}{}
	out := []CapabilityTool{}
	for _, c := range r.caps {
		for _, t := range c.Tools {
			if _, dup := seen[t.Name]; dup {
				continue
			}
			seen[t.Name] = struct{}{}
			out = append(out, t)
		}
	}
	return out
}

// GetInstructions returns the concatenated skill/plugin instructions for the
// system prompt, dropping empty entries.
func (r *CapabilityRegistry) GetInstructions() string {
	parts := []string{}
	for _, c := range r.caps {
		if c.Instructions != "" {
			parts = append(parts, c.Instructions)
		}
	}
	return strings.Join(parts, "\n\n")
}

// GetMCPServers returns all MCP server references across capabilities.
func (r *CapabilityRegistry) GetMCPServers() []MCPServerRef {
	out := []MCPServerRef{}
	for _, c := range r.caps {
		out = append(out, c.MCPServers...)
	}
	return out
}

// Compose merges a base system prompt with the loaded skill/plugin
// instructions and exposes the de-duplicated tools as agent.ToolSchema, ready
// to hand to the agent loop / bootstrap layer.
func (r *CapabilityRegistry) Compose(baseSystemPrompt string) (string, []agent.ToolSchema) {
	parts := []string{}
	if base := strings.TrimSpace(baseSystemPrompt); base != "" {
		parts = append(parts, base)
	}
	if instructions := r.GetInstructions(); instructions != "" {
		parts = append(parts, instructions)
	}
	systemPrompt := strings.Join(parts, "\n\n")

	tools := r.GetTools()
	schemas := make([]agent.ToolSchema, 0, len(tools))
	for _, t := range tools {
		schemas = append(schemas, t.ToToolSchema())
	}
	return systemPrompt, schemas
}

// LoadCapability sniffs a parsed input's format and loads it into a
// LoadedCapability. Recognized inputs:
//
//   - string starting with "---"               -> Anthropic skill (SKILL.md)
//   - []interface{}                            -> raw function tools
//   - map with openapi/swagger/paths           -> OpenAPI doc (openai-plugin)
//   - map with name_for_model/schema_version/api -> OpenAI plugin manifest
//   - map with commands/agents/skills/mcpServers/mcp/hooks -> Claude plugin
//   - map with a tools array                    -> raw function tools
//
// Anything else yields a *CapabilityFormatError.
func LoadCapability(input interface{}) (LoadedCapability, error) {
	switch in := input.(type) {
	case string:
		if strings.HasPrefix(strings.TrimLeft(in, " \t\r\n"), "---") {
			return ParseAnthropicSkill(in), nil
		}
		return LoadedCapability{}, &CapabilityFormatError{
			Message: "string input is not a SKILL.md (missing --- frontmatter)",
		}

	case []interface{}:
		return ParseFunctionTools(in, ""), nil

	case map[string]interface{}:
		// Sniff order is load-bearing; keep it faithful to the TS version.
		if hasAny(in, "openapi", "swagger", "paths") {
			return LoadedCapability{
				Name:         openapiTitle(in),
				Description:  openapiDescription(in),
				Format:       FormatOpenAIPlugin,
				Instructions: openapiDescription(in),
				Tools:        OpenAPIToTools(in, ""),
			}, nil
		}
		if hasAny(in, "name_for_model", "schema_version", "api") {
			return ParseOpenAIPlugin(in, map[string]interface{}{}), nil
		}
		if hasAny(in, "commands", "agents", "skills", "mcpServers", "mcp", "hooks") {
			return ParseClaudePlugin(in), nil
		}
		if toolsArr, ok := in["tools"].([]interface{}); ok {
			return ParseFunctionTools(toolsArr, ""), nil
		}
	}

	return LoadedCapability{}, &CapabilityFormatError{Message: "unrecognized capability format"}
}

// hasAny reports whether the map contains at least one of the given keys with a
// non-nil value.
func hasAny(m map[string]interface{}, keys ...string) bool {
	for _, k := range keys {
		if v, ok := m[k]; ok && v != nil {
			return true
		}
	}
	return false
}

// openapiTitle returns spec.info.title or "openapi".
func openapiTitle(spec map[string]interface{}) string {
	if info, ok := spec["info"].(map[string]interface{}); ok {
		if title, ok := info["title"].(string); ok && title != "" {
			return title
		}
	}
	return "openapi"
}

// openapiDescription returns spec.info.description or "".
func openapiDescription(spec map[string]interface{}) string {
	if info, ok := spec["info"].(map[string]interface{}); ok {
		if desc, ok := info["description"].(string); ok {
			return desc
		}
	}
	return ""
}
