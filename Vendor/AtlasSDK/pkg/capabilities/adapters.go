// Format adapters: each frontier skill/plugin format -> a LoadedCapability.
package capabilities

import (
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// frontmatterRe matches a leading `---` YAML frontmatter block followed by the
// markdown body. Mirrors the TS regex (single capture for frontmatter, single
// for body), anchored after trimming surrounding whitespace.
var frontmatterRe = regexp.MustCompile(`(?s)^---\s*\n(.*?)\n---\s*\n?(.*)$`)

// ParseAnthropicSkill parses an Anthropic Agent Skill (SKILL.md): YAML
// frontmatter + markdown body. The frontmatter is parsed with yaml.v3; the
// trimmed body becomes the instructions.
func ParseAnthropicSkill(skillMD string) LoadedCapability {
	frontmatter, body := splitFrontmatter(skillMD)

	name := "skill"
	if n, ok := frontmatter["name"].(string); ok && n != "" {
		name = n
	}
	description := ""
	if d, ok := frontmatter["description"].(string); ok {
		description = d
	}

	return LoadedCapability{
		Name:         name,
		Description:  description,
		Format:       FormatAnthropicSkill,
		Instructions: strings.TrimSpace(body),
		Tools:        []CapabilityTool{},
		Meta:         frontmatter,
	}
}

// ParseOpenAIPlugin combines an ai-plugin.json manifest with its OpenAPI spec.
func ParseOpenAIPlugin(manifest, openAPISpec map[string]interface{}) LoadedCapability {
	name := firstString(manifest, "name_for_model", "name_for_human")
	if name == "" {
		name = "plugin"
	}
	description := firstString(manifest, "description_for_model", "description_for_human")

	return LoadedCapability{
		Name:         name,
		Description:  description,
		Format:       FormatOpenAIPlugin,
		Instructions: description,
		Tools:        OpenAPIToTools(openAPISpec, name),
		Meta: map[string]interface{}{
			"auth": manifest["auth"],
			"api":  manifest["api"],
		},
	}
}

// ParseClaudePlugin parses a Claude Code plugin (plugin.json) with
// commands/agents/skills/hooks/mcp. Skills become instructions; mcpServers (or
// mcp) become normalized MCP server references.
func ParseClaudePlugin(plugin map[string]interface{}) LoadedCapability {
	name, _ := plugin["name"].(string)
	if name == "" {
		name = "plugin"
	}
	description, _ := plugin["description"].(string)

	instr := []string{}
	if skills, ok := plugin["skills"].([]interface{}); ok {
		for _, sRaw := range skills {
			switch s := sRaw.(type) {
			case string:
				instr = append(instr, s)
			case map[string]interface{}:
				if desc, ok := s["description"].(string); ok && desc != "" {
					sname, _ := s["name"].(string)
					line := strings.TrimSpace(sname + ": " + desc)
					instr = append(instr, line)
				}
			}
		}
	}

	instructions := description
	if len(instr) > 0 {
		instructions = strings.Join(instr, "\n")
	}

	mcpRaw, ok := plugin["mcpServers"]
	if !ok {
		mcpRaw = plugin["mcp"]
	}

	return LoadedCapability{
		Name:         name,
		Description:  description,
		Format:       FormatClaudePlugin,
		Instructions: instructions,
		Tools:        []CapabilityTool{},
		MCPServers:   normalizeMCPServers(mcpRaw),
		Meta: map[string]interface{}{
			"commands": plugin["commands"],
			"agents":   plugin["agents"],
			"version":  plugin["version"],
		},
	}
}

// ParseFunctionTools normalizes raw function-tool definitions, handling both
// OpenAI ({type:"function", function:{...}}) and Anthropic ({name, input_schema})
// shapes.
func ParseFunctionTools(tools []interface{}, source string) LoadedCapability {
	if source == "" {
		source = "function-tools"
	}

	normalized := []CapabilityTool{}
	for _, tRaw := range tools {
		t, ok := tRaw.(map[string]interface{})
		if !ok {
			continue
		}
		// OpenAI wraps the definition under "function"; Anthropic puts it
		// at the top level. Fall back to the whole object.
		fn := t
		if inner, ok := t["function"].(map[string]interface{}); ok {
			fn = inner
		}

		fnName, ok := fn["name"].(string)
		if !ok || fnName == "" {
			continue
		}
		description, _ := fn["description"].(string)

		inputSchema := firstSchema(fn, "parameters", "input_schema", "inputSchema")
		if inputSchema == nil {
			inputSchema = map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			}
		}

		normalized = append(normalized, CapabilityTool{
			Name:        fnName,
			Description: description,
			InputSchema: inputSchema,
			Source:      source,
			Invocation:  &ToolInvocation{Kind: InvocationFunction},
		})
	}

	return LoadedCapability{
		Name:        source,
		Description: "Function tools",
		Format:      FormatFunctionTools,
		Tools:       normalized,
	}
}

// ---- helpers ----

// normalizeMCPServers converts an mcpServers map (name -> config) or list of
// {name, transport} objects into normalized MCPServerRef entries.
func normalizeMCPServers(mcp interface{}) []MCPServerRef {
	if mcp == nil {
		return nil
	}
	switch m := mcp.(type) {
	case []interface{}:
		out := make([]MCPServerRef, 0, len(m))
		for _, eRaw := range m {
			e, ok := eRaw.(map[string]interface{})
			if !ok {
				continue
			}
			name, _ := e["name"].(string)
			transport := e["transport"]
			if transport == nil {
				transport = e
			}
			out = append(out, MCPServerRef{Name: name, Transport: transport})
		}
		return out
	case map[string]interface{}:
		out := make([]MCPServerRef, 0, len(m))
		for name, cfg := range m {
			out = append(out, MCPServerRef{Name: name, Transport: cfg})
		}
		return out
	}
	return nil
}

// splitFrontmatter splits a SKILL.md into its parsed YAML frontmatter and body.
// If no frontmatter delimiter is present, the whole input is returned as body
// with empty frontmatter.
func splitFrontmatter(md string) (map[string]interface{}, string) {
	trimmed := strings.TrimSpace(md)
	m := frontmatterRe.FindStringSubmatch(trimmed)
	if m == nil {
		return map[string]interface{}{}, md
	}

	frontmatter := map[string]interface{}{}
	if err := yaml.Unmarshal([]byte(m[1]), &frontmatter); err != nil || frontmatter == nil {
		frontmatter = map[string]interface{}{}
	}
	return frontmatter, m[2]
}

// firstString returns the first non-empty string value found among the given
// keys (mirrors TS `a ?? b ?? ”`).
func firstString(m map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

// firstSchema returns the first map-typed value found among the given keys
// (mirrors TS `parameters ?? input_schema ?? inputSchema ?? {...}`).
func firstSchema(m map[string]interface{}, keys ...string) map[string]interface{} {
	for _, k := range keys {
		if v, ok := m[k].(map[string]interface{}); ok {
			return v
		}
	}
	return nil
}
