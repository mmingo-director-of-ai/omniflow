package capabilities

import (
	"reflect"
	"strings"
	"testing"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

const skillMD = `---
name: log-analyzer
description: Analyze syslog files for anomalies
allowed-tools: [grep, read]
---
When given a log, look for repeated failures and traffic spikes.`

// openapiDoc mirrors the TS OPENAPI fixture, built directly as a Go map so no
// JSON number parsing is involved.
func openapiDoc() map[string]interface{} {
	return map[string]interface{}{
		"openapi": "3.0.0",
		"info":    map[string]interface{}{"title": "Weather API"},
		"servers": []interface{}{
			map[string]interface{}{"url": "https://api.example.com"},
		},
		"paths": map[string]interface{}{
			"/weather/{city}": map[string]interface{}{
				"get": map[string]interface{}{
					"operationId": "getWeather",
					"summary":     "Get current weather",
					"parameters": []interface{}{
						map[string]interface{}{
							"name":     "city",
							"in":       "path",
							"required": true,
							"schema":   map[string]interface{}{"type": "string"},
						},
						map[string]interface{}{
							"name":   "units",
							"in":     "query",
							"schema": map[string]interface{}{"type": "string"},
						},
					},
				},
			},
			"/alerts": map[string]interface{}{
				"post": map[string]interface{}{
					"operationId": "createAlert",
					"requestBody": map[string]interface{}{
						"content": map[string]interface{}{
							"application/json": map[string]interface{}{
								"schema": map[string]interface{}{
									"type": "object",
									"properties": map[string]interface{}{
										"city":      map[string]interface{}{"type": "string"},
										"threshold": map[string]interface{}{"type": "number"},
									},
									"required": []interface{}{"city"},
								},
							},
						},
					},
				},
			},
		},
	}
}

func openaiManifest() map[string]interface{} {
	return map[string]interface{}{
		"schema_version":        "v1",
		"name_for_model":        "weather",
		"description_for_model": "Weather lookups",
		"api": map[string]interface{}{
			"type": "openapi",
			"url":  "https://api.example.com/openapi.json",
		},
	}
}

func claudePlugin() map[string]interface{} {
	return map[string]interface{}{
		"name":        "secops",
		"description": "SecOps toolkit",
		"version":     "1.0.0",
		"skills": []interface{}{
			map[string]interface{}{"name": "triage", "description": "Triage security alerts"},
		},
		"mcpServers": map[string]interface{}{
			"sentinel": map[string]interface{}{
				"transport": map[string]interface{}{"type": "stdio", "command": "sentinel-mcp"},
			},
		},
	}
}

func toolsByName(tools []CapabilityTool) map[string]CapabilityTool {
	out := map[string]CapabilityTool{}
	for _, t := range tools {
		out[t.Name] = t
	}
	return out
}

func schemaNames(schemas []agent.ToolSchema) []string {
	out := make([]string, len(schemas))
	for i, s := range schemas {
		out[i] = s.Name
	}
	return out
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

func TestParseAnthropicSkill(t *testing.T) {
	c := ParseAnthropicSkill(skillMD)
	if c.Format != FormatAnthropicSkill {
		t.Fatalf("format = %q, want %q", c.Format, FormatAnthropicSkill)
	}
	if c.Name != "log-analyzer" {
		t.Fatalf("name = %q, want log-analyzer", c.Name)
	}
	if !strings.Contains(c.Description, "anomalies") {
		t.Fatalf("description = %q, want to contain 'anomalies'", c.Description)
	}
	if !strings.Contains(c.Instructions, "traffic spikes") {
		t.Fatalf("instructions = %q, want to contain 'traffic spikes'", c.Instructions)
	}
	// yaml.v3 unmarshals an inline array into []interface{}, not []string.
	want := []interface{}{"grep", "read"}
	if got := c.Meta["allowed-tools"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("meta[allowed-tools] = %#v, want %#v", got, want)
	}
}

func TestOpenAPIToTools(t *testing.T) {
	tools := OpenAPIToTools(openapiDoc(), "")
	byName := toolsByName(tools)

	gw, ok := byName["getWeather"]
	if !ok {
		t.Fatal("expected getWeather tool")
	}
	props, _ := gw.InputSchema["properties"].(map[string]interface{})
	if _, ok := props["city"]; !ok {
		t.Fatal("getWeather.inputSchema.properties.city missing")
	}
	req, _ := gw.InputSchema["required"].([]string)
	if !contains(req, "city") {
		t.Fatalf("getWeather.inputSchema.required = %#v, want to contain 'city'", req)
	}
	if gw.Invocation == nil || gw.Invocation.Method != "GET" {
		t.Fatalf("getWeather invocation method = %v, want GET", gw.Invocation)
	}

	ca, ok := byName["createAlert"]
	if !ok {
		t.Fatal("expected createAlert tool")
	}
	caProps, _ := ca.InputSchema["properties"].(map[string]interface{})
	if _, ok := caProps["threshold"]; !ok {
		t.Fatal("createAlert.inputSchema.properties.threshold missing")
	}
	if ca.Invocation == nil || ca.Invocation.Method != "POST" {
		t.Fatalf("createAlert invocation method = %v, want POST", ca.Invocation)
	}
	// Additive Go fields: BodyKeys captured from the JSON request body.
	if !contains(ca.Invocation.BodyKeys, "city") || !contains(ca.Invocation.BodyKeys, "threshold") {
		t.Fatalf("createAlert BodyKeys = %#v, want city+threshold", ca.Invocation.BodyKeys)
	}
}

func TestParseOpenAIPlugin(t *testing.T) {
	c := ParseOpenAIPlugin(openaiManifest(), openapiDoc())
	if c.Format != FormatOpenAIPlugin {
		t.Fatalf("format = %q, want %q", c.Format, FormatOpenAIPlugin)
	}
	if c.Name != "weather" {
		t.Fatalf("name = %q, want weather", c.Name)
	}
	if !contains(toolNames(c.Tools), "getWeather") {
		t.Fatalf("tools = %#v, want to contain getWeather", toolNames(c.Tools))
	}
}

func TestParseClaudePlugin(t *testing.T) {
	c := ParseClaudePlugin(claudePlugin())
	if c.Format != FormatClaudePlugin {
		t.Fatalf("format = %q, want %q", c.Format, FormatClaudePlugin)
	}
	if !strings.Contains(c.Instructions, "Triage security alerts") {
		t.Fatalf("instructions = %q, want to contain 'Triage security alerts'", c.Instructions)
	}
	if len(c.MCPServers) != 1 {
		t.Fatalf("mcpServers len = %d, want 1", len(c.MCPServers))
	}
	if c.MCPServers[0].Name != "sentinel" {
		t.Fatalf("mcpServers[0].name = %q, want sentinel", c.MCPServers[0].Name)
	}
}

func TestParseFunctionTools(t *testing.T) {
	openai := ParseFunctionTools([]interface{}{
		map[string]interface{}{
			"type": "function",
			"function": map[string]interface{}{
				"name":        "add",
				"description": "Add",
				"parameters": map[string]interface{}{
					"type":       "object",
					"properties": map[string]interface{}{"a": map[string]interface{}{"type": "number"}},
					"required":   []interface{}{"a"},
				},
			},
		},
	}, "")
	if openai.Tools[0].Name != "add" {
		t.Fatalf("openai tool name = %q, want add", openai.Tools[0].Name)
	}
	req, _ := openai.Tools[0].InputSchema["required"].([]interface{})
	if !containsIface(req, "a") {
		t.Fatalf("openai required = %#v, want to contain 'a'", req)
	}

	anthropic := ParseFunctionTools([]interface{}{
		map[string]interface{}{
			"name":        "sub",
			"description": "Subtract",
			"input_schema": map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{"x": map[string]interface{}{"type": "number"}},
			},
		},
	}, "")
	if anthropic.Tools[0].Name != "sub" {
		t.Fatalf("anthropic tool name = %q, want sub", anthropic.Tools[0].Name)
	}
	props, _ := anthropic.Tools[0].InputSchema["properties"].(map[string]interface{})
	if _, ok := props["x"]; !ok {
		t.Fatal("anthropic inputSchema.properties.x missing")
	}
}

func TestCapabilityRegistryCompose(t *testing.T) {
	reg := NewCapabilityRegistry()
	reg.Add(ParseAnthropicSkill(skillMD))
	reg.Add(ParseOpenAIPlugin(openaiManifest(), openapiDoc()))

	systemPrompt, schemas := reg.Compose("You are Atlas.")
	if !strings.HasPrefix(systemPrompt, "You are Atlas.") {
		t.Fatalf("systemPrompt = %q, want to start with 'You are Atlas.'", systemPrompt)
	}
	if !strings.Contains(systemPrompt, "traffic spikes") {
		t.Fatalf("systemPrompt missing injected skill instructions: %q", systemPrompt)
	}
	// Compose exposes the tools as []agent.ToolSchema (the ownership boundary).
	if !contains(schemaNames(schemas), "getWeather") {
		t.Fatalf("schemas = %#v, want to contain getWeather", schemaNames(schemas))
	}
}

func TestCapabilityRegistryDedup(t *testing.T) {
	reg := NewCapabilityRegistry()
	reg.Add(ParseFunctionTools([]interface{}{map[string]interface{}{"name": "add"}}, ""))
	reg.Add(ParseFunctionTools([]interface{}{map[string]interface{}{"name": "add"}}, ""))
	if got := len(reg.GetTools()); got != 1 {
		t.Fatalf("GetTools len = %d, want 1 (de-dup by name)", got)
	}
}

func TestLoadCapabilitySniffing(t *testing.T) {
	c, err := LoadCapability(skillMD)
	if err != nil || c.Format != FormatAnthropicSkill {
		t.Fatalf("skill sniff: format=%q err=%v", c.Format, err)
	}

	c, err = LoadCapability(openapiDoc())
	if err != nil {
		t.Fatalf("openapi sniff err: %v", err)
	}
	if !contains(toolNames(c.Tools), "getWeather") {
		t.Fatalf("openapi sniff tools = %#v, want getWeather", toolNames(c.Tools))
	}

	c, err = LoadCapability([]interface{}{map[string]interface{}{"name": "x"}})
	if err != nil || c.Format != FormatFunctionTools {
		t.Fatalf("function-tools sniff: format=%q err=%v", c.Format, err)
	}

	c, err = LoadCapability(claudePlugin())
	if err != nil || c.Format != FormatClaudePlugin {
		t.Fatalf("claude-plugin sniff: format=%q err=%v", c.Format, err)
	}

	c, err = LoadCapability(openaiManifest())
	if err != nil || c.Format != FormatOpenAIPlugin {
		t.Fatalf("openai-plugin sniff: format=%q err=%v", c.Format, err)
	}

	_, err = LoadCapability(42)
	if err == nil {
		t.Fatal("expected error for unrecognized format")
	}
	if _, ok := err.(*CapabilityFormatError); !ok {
		t.Fatalf("error type = %T, want *CapabilityFormatError", err)
	}
}

// helpers used only by tests

func toolNames(tools []CapabilityTool) []string {
	out := make([]string, len(tools))
	for i, t := range tools {
		out[i] = t.Name
	}
	return out
}

func containsIface(list []interface{}, want string) bool {
	for _, v := range list {
		if s, ok := v.(string); ok && s == want {
			return true
		}
	}
	return false
}
