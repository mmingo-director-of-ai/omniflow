package bootstrap

import (
	"encoding/json"
	"strings"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

// BuildEnvelopeSchema builds the tool-call envelope JSON Schema for constrained
// decoding (per-tool oneOf on name+arguments, plus a content channel).
func BuildEnvelopeSchema(tools []agent.ToolSchema) map[string]interface{} {
	branches := make([]interface{}, 0, len(tools))
	for _, t := range tools {
		schema := t.InputSchema
		if schema == nil {
			schema = map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
		}
		branches = append(branches, map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"name":      map[string]interface{}{"const": t.Name},
				"arguments": schema,
			},
			"required":             []string{"name", "arguments"},
			"additionalProperties": false,
		})
	}
	var item interface{}
	if len(branches) == 1 {
		item = branches[0]
	} else {
		item = map[string]interface{}{"oneOf": branches}
	}
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"tool_calls": map[string]interface{}{"type": "array", "items": item},
			"content":    map[string]interface{}{"type": "string"},
		},
		"additionalProperties": false,
	}
}

// RenderEnvelopePrompt instructs the model to emit the envelope.
func RenderEnvelopePrompt(tools []agent.ToolSchema, systemPrompt string) string {
	lines := []string{}
	if s := strings.TrimSpace(systemPrompt); s != "" {
		lines = append(lines, s)
	}
	lines = append(lines,
		"Respond with a SINGLE JSON object and nothing else.",
		`To call tools: {"tool_calls": [{"name": "<tool>", "arguments": { ... }}]}`,
		`When you are done: {"content": "<your final answer>"}`,
		"",
		"Available tools:",
		renderToolCatalogue(tools),
	)
	return strings.Join(lines, "\n")
}

// ParseEnvelope parses the (constraint-guaranteed) envelope JSON.
func ParseEnvelope(text string) ParseResult {
	raw := strings.TrimSpace(text)
	var obj struct {
		ToolCalls []rawCall `json:"tool_calls"`
		Content   string    `json:"content"`
	}
	if json.Unmarshal([]byte(raw), &obj) != nil {
		sliced := firstJSONObject(raw)
		if sliced == "" || json.Unmarshal([]byte(sliced), &obj) != nil {
			return ParseResult{Content: raw, Malformed: nonEmpty(raw)}
		}
	}
	var calls []agent.ToolCallData
	var malformed []string
	for _, c := range obj.ToolCalls {
		appendCall(c, &calls, &malformed)
	}
	return ParseResult{Content: obj.Content, ToolCalls: calls, Malformed: malformed}
}

func nonEmpty(s string) []string {
	if s == "" {
		return nil
	}
	return []string{s}
}
