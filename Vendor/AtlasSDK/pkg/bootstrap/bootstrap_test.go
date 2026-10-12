package bootstrap

import (
	"context"
	"testing"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

var weatherTool = agent.ToolSchema{
	Name:        "get_weather",
	Description: "Get the weather for a city",
	InputSchema: map[string]interface{}{"type": "object", "properties": map[string]interface{}{"city": map[string]interface{}{"type": "string"}}, "required": []interface{}{"city"}},
}

// --- Conformance: these goldens mirror the TS codec tests exactly, so the
// json/hermes parsers are guaranteed behaviourally identical across SDKs. ---

func TestJSONParseParity(t *testing.T) {
	r := JSONDialect.Parse("Let me check.\n"+"```tool_call\n{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}\n```", []agent.ToolSchema{weatherTool})
	if len(r.ToolCalls) != 1 || r.ToolCalls[0].Name != "get_weather" {
		t.Fatalf("expected 1 get_weather call, got %+v", r.ToolCalls)
	}
	if r.ToolCalls[0].Arguments["city"] != "Paris" {
		t.Fatalf("expected city=Paris, got %v", r.ToolCalls[0].Arguments["city"])
	}
	if r.Content != "Let me check." {
		t.Fatalf("expected stripped content, got %q", r.Content)
	}
}

func TestJSONParseArray(t *testing.T) {
	r := JSONDialect.Parse("```tool_call\n[{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}},{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Rome\"}}]\n```", nil)
	if len(r.ToolCalls) != 2 {
		t.Fatalf("expected 2 calls, got %d", len(r.ToolCalls))
	}
}

func TestJSONFinalAnswer(t *testing.T) {
	r := JSONDialect.Parse("The weather in Paris is sunny.", nil)
	if len(r.ToolCalls) != 0 || r.Content != "The weather in Paris is sunny." {
		t.Fatalf("expected final answer, got %+v", r)
	}
}

func TestJSONMalformed(t *testing.T) {
	r := JSONDialect.Parse("```tool_call\n{not json}\n```", nil)
	if len(r.ToolCalls) != 0 || len(r.Malformed) == 0 {
		t.Fatalf("expected malformed, got %+v", r)
	}
}

func TestHermesParseParity(t *testing.T) {
	r := HermesDialect.Parse("Sure.\n<tool_call>\n{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}\n</tool_call>", nil)
	if len(r.ToolCalls) != 1 || r.ToolCalls[0].Name != "get_weather" {
		t.Fatalf("expected 1 get_weather call, got %+v", r.ToolCalls)
	}
	if r.ToolCalls[0].Arguments["city"] != "Paris" || r.Content != "Sure." {
		t.Fatalf("unexpected parse: %+v", r)
	}
}

func TestEnvelopeParity(t *testing.T) {
	r := ParseEnvelope(`{"tool_calls":[{"name":"get_weather","arguments":{"city":"Paris"}}]}`)
	if len(r.ToolCalls) != 1 || r.ToolCalls[0].Name != "get_weather" {
		t.Fatalf("expected 1 call, got %+v", r.ToolCalls)
	}
	c := ParseEnvelope(`{"content":"done"}`)
	if len(c.ToolCalls) != 0 || c.Content != "done" {
		t.Fatalf("expected content channel, got %+v", c)
	}
	s := BuildEnvelopeSchema([]agent.ToolSchema{weatherTool})
	props := s["properties"].(map[string]interface{})
	if _, ok := props["tool_calls"]; !ok {
		t.Fatalf("envelope missing tool_calls")
	}
}

// --- BootstrapProvider (the wrapping adapter over agent.Provider) ---

type queueProvider struct {
	turns []string
	calls int
}

func (q *queueProvider) Generate(_ context.Context, _ []agent.Message, _ []agent.ToolSchema) (*agent.GenerateResult, error) {
	c := ""
	if q.calls < len(q.turns) {
		c = q.turns[q.calls]
	} else if len(q.turns) > 0 {
		c = q.turns[len(q.turns)-1]
	}
	q.calls++
	return &agent.GenerateResult{Content: c}, nil
}

func TestBootstrapPromptedPath(t *testing.T) {
	q := &queueProvider{turns: []string{"<tool_call>\n{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}\n</tool_call>"}}
	bp := Bootstrap(q, "qwen2.5-coder:7b", Config{}) // qwen -> hermes
	res, err := bp.Generate(context.Background(), []agent.Message{{Role: "user", Content: "weather?"}}, []agent.ToolSchema{weatherTool})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.ToolCalls) != 1 || res.ToolCalls[0].Name != "get_weather" {
		t.Fatalf("expected get_weather call, got %+v", res.ToolCalls)
	}
	if res.ToolCalls[0].Arguments["city"] != "Paris" {
		t.Fatalf("expected city=Paris, got %v", res.ToolCalls[0].Arguments["city"])
	}
}

func TestBootstrapRepairsUnknownTool(t *testing.T) {
	q := &queueProvider{turns: []string{
		"<tool_call>\n{\"name\":\"totally_not_a_tool\",\"arguments\":{}}\n</tool_call>",
		"<tool_call>\n{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}\n</tool_call>",
	}}
	bp := Bootstrap(q, "qwen2.5-coder:7b", Config{MaxRetries: 2})
	res, err := bp.Generate(context.Background(), []agent.Message{{Role: "user", Content: "weather?"}}, []agent.ToolSchema{weatherTool})
	if err != nil {
		t.Fatal(err)
	}
	if q.calls != 2 {
		t.Fatalf("expected a repair retry (2 inner calls), got %d", q.calls)
	}
	if len(res.ToolCalls) != 1 || res.ToolCalls[0].Name != "get_weather" {
		t.Fatalf("expected recovered get_weather call, got %+v", res.ToolCalls)
	}
}

func TestBootstrapFuzzyMatch(t *testing.T) {
	q := &queueProvider{turns: []string{"<tool_call>\n{\"name\":\"get_weathr\",\"arguments\":{\"city\":\"Paris\"}}\n</tool_call>"}}
	bp := Bootstrap(q, "qwen2.5-coder:7b", Config{})
	res, err := bp.Generate(context.Background(), []agent.Message{{Role: "user", Content: "weather?"}}, []agent.ToolSchema{weatherTool})
	if err != nil {
		t.Fatal(err)
	}
	if q.calls != 1 {
		t.Fatalf("expected no retry, got %d inner calls", q.calls)
	}
	if len(res.ToolCalls) != 1 || res.ToolCalls[0].Name != "get_weather" {
		t.Fatalf("expected fuzzy-corrected get_weather, got %+v", res.ToolCalls)
	}
}

func TestBootstrapFinalAnswer(t *testing.T) {
	q := &queueProvider{turns: []string{"It is sunny in Paris."}}
	bp := Bootstrap(q, "qwen2.5-coder:7b", Config{})
	res, err := bp.Generate(context.Background(), []agent.Message{{Role: "user", Content: "weather?"}}, []agent.ToolSchema{weatherTool})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.ToolCalls) != 0 || res.Content != "It is sunny in Paris." {
		t.Fatalf("expected final answer, got %+v", res)
	}
}
