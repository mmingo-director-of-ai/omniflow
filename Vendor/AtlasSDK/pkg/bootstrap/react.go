package bootstrap

import (
	"encoding/json"
	"regexp"
	"strings"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

var (
	reactActionRe  = regexp.MustCompile(`(?is)Action:\s*([^\n]+)[\r\n]+\s*Action Input:\s*(.*?)(?:\n\s*(?:Observation:|Thought:|Final Answer:)|$)`)
	reactFinalRe   = regexp.MustCompile(`(?is)Final Answer:\s*(.*)$`)
	reactThoughtRe = regexp.MustCompile(`(?i)Thought:\s*([^\n]*)`)
)

type reactDialect struct{}

// ReactDialect is the Thought/Action/Action Input/Observation dialect.
var ReactDialect DialectCodec = reactDialect{}

func (reactDialect) ID() string { return "react" }

func (reactDialect) RenderSystemPrompt(tools []agent.ToolSchema, systemPrompt string) string {
	names := make([]string, 0, len(tools))
	for _, t := range tools {
		names = append(names, t.Name)
	}
	lines := []string{}
	if s := strings.TrimSpace(systemPrompt); s != "" {
		lines = append(lines, s)
	}
	lines = append(lines,
		"Answer the user using the available tools. Use EXACTLY this format:",
		"",
		"Thought: <your reasoning>",
		"Action: <one of: "+strings.Join(names, ", ")+">",
		"Action Input: <a JSON object of arguments>",
		"",
		`After each Action you will receive an "Observation:". Repeat Thought/Action/Action Input as needed.`,
		"When you have the final answer, respond with:",
		"",
		"Thought: <reasoning>",
		"Final Answer: <your answer>",
		"",
		"Available tools:",
		renderToolCatalogue(tools),
	)
	return strings.Join(lines, "\n")
}

func (reactDialect) RenderTranscript(messages []agent.Message) []agent.Message {
	out := make([]agent.Message, 0, len(messages))
	for _, m := range messages {
		switch m.Role {
		case "system":
			continue
		case "tool":
			out = append(out, agent.Message{Role: "user", Content: "Observation: " + m.Content})
		default:
			out = append(out, agent.Message{Role: m.Role, Content: m.Content})
		}
	}
	return out
}

func (reactDialect) Parse(text string, _ []agent.ToolSchema) ParseResult {
	action := reactActionRe.FindStringSubmatchIndex(text)
	final := reactFinalRe.FindStringSubmatchIndex(text)

	if action != nil && (final == nil || action[0] < final[0]) {
		name := strings.TrimSpace(text[action[2]:action[3]])
		inputRaw := strings.TrimSpace(text[action[4]:action[5]])
		thought := reactThought(text)
		args := parseArgs(inputRaw)
		if args == nil {
			return ParseResult{Content: thought, Malformed: []string{inputRaw}}
		}
		return ParseResult{Content: thought, ToolCalls: []agent.ToolCallData{{ID: genID(), Name: name, Arguments: args}}}
	}
	if final != nil {
		return ParseResult{Content: strings.TrimSpace(text[final[2]:final[3]])}
	}
	return ParseResult{Content: strings.TrimSpace(text)}
}

func reactThought(t string) string {
	m := reactThoughtRe.FindStringSubmatch(t)
	if len(m) > 1 {
		return strings.TrimSpace(m[1])
	}
	return ""
}

func parseArgs(raw string) map[string]interface{} {
	var m map[string]interface{}
	if json.Unmarshal([]byte(raw), &m) == nil && m != nil {
		return m
	}
	if obj := firstJSONObject(raw); obj != "" {
		if json.Unmarshal([]byte(obj), &m) == nil && m != nil {
			return m
		}
	}
	return nil
}
