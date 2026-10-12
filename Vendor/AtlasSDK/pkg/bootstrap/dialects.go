// Package bootstrap lets a raw LLM (no native tool-calling) use tools/MCP via
// prompt-injected tool schemas + text-parsed tool-call extraction + repair.
//
// It is the Go port of packages/atlas-core/src/bootstrap (TS). The dialect
// codecs here are kept behaviourally identical to the TS codecs so the shared
// conformance suite passes against both SDKs.
package bootstrap

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"sync/atomic"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

// ParseResult is the output of parsing a model's raw text into tool calls.
type ParseResult struct {
	Content   string
	ToolCalls []agent.ToolCallData
	Malformed []string
}

// DialectCodec is a render+parse pair for one tool-call dialect.
type DialectCodec interface {
	ID() string
	RenderSystemPrompt(tools []agent.ToolSchema, systemPrompt string) string
	RenderTranscript(messages []agent.Message) []agent.Message
	Parse(text string, tools []agent.ToolSchema) ParseResult
}

const tcFence = "```"

var (
	jsonFenceRe = regexp.MustCompile("(?s)" + tcFence + "tool_call\\s*(.*?)" + tcFence)
	hermesRe    = regexp.MustCompile("(?s)<tool_call>\\s*(.*?)</tool_call>")
)

var idSeq int64

func genID() string {
	return fmt.Sprintf("call_%d", atomic.AddInt64(&idSeq, 1))
}

type rawCall struct {
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
	Args      map[string]interface{} `json:"args"`
}

func appendCall(c rawCall, calls *[]agent.ToolCallData, malformed *[]string) {
	if c.Name == "" {
		b, _ := json.Marshal(c)
		*malformed = append(*malformed, string(b))
		return
	}
	args := c.Arguments
	if args == nil {
		args = c.Args
	}
	if args == nil {
		args = map[string]interface{}{}
	}
	*calls = append(*calls, agent.ToolCallData{ID: genID(), Name: c.Name, Arguments: args})
}

// collectJSON parses one tool-call payload (object or array) into calls.
func collectJSON(raw string, calls *[]agent.ToolCallData, malformed *[]string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return
	}
	if strings.HasPrefix(raw, "[") {
		var arr []rawCall
		if err := json.Unmarshal([]byte(raw), &arr); err != nil {
			*malformed = append(*malformed, raw)
			return
		}
		for _, c := range arr {
			appendCall(c, calls, malformed)
		}
		return
	}
	var c rawCall
	if err := json.Unmarshal([]byte(raw), &c); err != nil {
		*malformed = append(*malformed, raw)
		return
	}
	appendCall(c, calls, malformed)
}

func renderToolCatalogue(tools []agent.ToolSchema) string {
	parts := make([]string, 0, len(tools))
	for _, t := range tools {
		schema := t.InputSchema
		if schema == nil {
			schema = map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
		}
		b, _ := json.Marshal(schema)
		parts = append(parts, fmt.Sprintf("- %s: %s\n  parameters (JSON Schema): %s", t.Name, t.Description, string(b)))
	}
	return strings.Join(parts, "\n")
}

func toolResultJSON(content string) string {
	var v interface{}
	if json.Unmarshal([]byte(content), &v) == nil {
		return content
	}
	b, _ := json.Marshal(content)
	return string(b)
}

// ---- json dialect ----

type jsonDialect struct{}

// JSONDialect is the fenced JSON tool-call dialect (default).
var JSONDialect DialectCodec = jsonDialect{}

func (jsonDialect) ID() string { return "json" }

func (jsonDialect) RenderSystemPrompt(tools []agent.ToolSchema, systemPrompt string) string {
	lines := []string{}
	if s := strings.TrimSpace(systemPrompt); s != "" {
		lines = append(lines, s)
	}
	lines = append(lines,
		"You can use tools. To call a tool, reply with a fenced block exactly like:",
		tcFence+"tool_call",
		`{"name": "<tool_name>", "arguments": { /* values matching the tool's JSON Schema */ }}`,
		tcFence,
		"To call multiple tools in one turn, put a JSON array of such objects inside one block.",
		"When you are done and have the final answer, reply in plain text with NO tool_call block.",
		"",
		"Available tools:",
		renderToolCatalogue(tools),
	)
	return strings.Join(lines, "\n")
}

func (jsonDialect) RenderTranscript(messages []agent.Message) []agent.Message {
	out := make([]agent.Message, 0, len(messages))
	for _, m := range messages {
		switch m.Role {
		case "system":
			continue
		case "tool":
			out = append(out, agent.Message{Role: "user", Content: tcFence + "tool_response\n" + toolResultJSON(m.Content) + "\n" + tcFence})
		default:
			out = append(out, agent.Message{Role: m.Role, Content: m.Content})
		}
	}
	return out
}

func (jsonDialect) Parse(text string, _ []agent.ToolSchema) ParseResult {
	var calls []agent.ToolCallData
	var malformed []string
	stripped := text
	matches := jsonFenceRe.FindAllStringSubmatch(text, -1)
	if len(matches) > 0 {
		for _, mm := range matches {
			stripped = strings.Replace(stripped, mm[0], "", 1)
			collectJSON(mm[1], &calls, &malformed)
		}
	} else if obj := firstJSONObject(text); obj != "" && strings.Contains(obj, "\"name\"") {
		collectJSON(obj, &calls, &malformed)
		stripped = strings.Replace(stripped, obj, "", 1)
	}
	return ParseResult{Content: strings.TrimSpace(stripped), ToolCalls: calls, Malformed: malformed}
}

// ---- hermes dialect ----

type hermesDialect struct{}

// HermesDialect is the <tool_call> XML dialect (Qwen/Hermes/Nous).
var HermesDialect DialectCodec = hermesDialect{}

func (hermesDialect) ID() string { return "hermes" }

func (hermesDialect) RenderSystemPrompt(tools []agent.ToolSchema, systemPrompt string) string {
	toolLines := make([]string, 0, len(tools))
	for _, t := range tools {
		schema := t.InputSchema
		if schema == nil {
			schema = map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
		}
		b, _ := json.Marshal(map[string]interface{}{"name": t.Name, "description": t.Description, "parameters": schema})
		toolLines = append(toolLines, string(b))
	}
	lines := []string{}
	if s := strings.TrimSpace(systemPrompt); s != "" {
		lines = append(lines, s)
	}
	lines = append(lines,
		"You are a function-calling AI. You are given functions inside <tools></tools> tags.",
		"To call a function, return a JSON object with its name and arguments inside <tool_call></tool_call> tags:",
		"<tool_call>",
		`{"name": "<function-name>", "arguments": {<arguments matching the schema>}}`,
		"</tool_call>",
		"When you have the final answer, reply in plain text with no <tool_call> tags.",
		"",
		"<tools>",
		strings.Join(toolLines, "\n"),
		"</tools>",
	)
	return strings.Join(lines, "\n")
}

func (hermesDialect) RenderTranscript(messages []agent.Message) []agent.Message {
	out := make([]agent.Message, 0, len(messages))
	for _, m := range messages {
		switch m.Role {
		case "system":
			continue
		case "tool":
			out = append(out, agent.Message{Role: "user", Content: "<tool_response>\n" + toolResultJSON(m.Content) + "\n</tool_response>"})
		default:
			out = append(out, agent.Message{Role: m.Role, Content: m.Content})
		}
	}
	return out
}

func (hermesDialect) Parse(text string, _ []agent.ToolSchema) ParseResult {
	var calls []agent.ToolCallData
	var malformed []string
	stripped := text
	for _, mm := range hermesRe.FindAllStringSubmatch(text, -1) {
		stripped = strings.Replace(stripped, mm[0], "", 1)
		raw := strings.TrimSpace(mm[1])
		var c rawCall
		if err := json.Unmarshal([]byte(raw), &c); err != nil || c.Name == "" {
			malformed = append(malformed, raw)
			continue
		}
		appendCall(c, &calls, &malformed)
	}
	return ParseResult{Content: strings.TrimSpace(stripped), ToolCalls: calls, Malformed: malformed}
}

// firstJSONObject returns the first balanced {...} substring, or "".
func firstJSONObject(text string) string {
	start := strings.IndexByte(text, '{')
	if start == -1 {
		return ""
	}
	depth, inStr, esc := 0, false, false
	for i := start; i < len(text); i++ {
		ch := text[i]
		if inStr {
			switch {
			case esc:
				esc = false
			case ch == '\\':
				esc = true
			case ch == '"':
				inStr = false
			}
			continue
		}
		switch ch {
		case '"':
			inStr = true
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return text[start : i+1]
			}
		}
	}
	return ""
}
