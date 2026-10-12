package bootstrap

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

// ---- fixture provider (implements agent.Provider AND ConstrainableProvider) ----

type fixtureProvider struct {
	prompted    map[string][]string
	constrained map[string][]string
	curP        []string
	curC        []string
	cursor      int
}

func (f *fixtureProvider) setTask(id string) {
	f.curP = f.prompted[id]
	if f.curP == nil {
		f.curP = []string{""}
	}
	f.curC = f.constrained[id]
	if f.curC == nil {
		f.curC = f.curP
	}
	f.cursor = 0
}

func pick(seq []string, i int) string {
	if len(seq) == 0 {
		return ""
	}
	if i >= len(seq) {
		return seq[len(seq)-1]
	}
	return seq[i]
}

func (f *fixtureProvider) Generate(_ context.Context, _ []agent.Message, _ []agent.ToolSchema) (*agent.GenerateResult, error) {
	out := pick(f.curP, f.cursor)
	f.cursor++
	return &agent.GenerateResult{Content: out}, nil
}

func (f *fixtureProvider) GenerateConstrained(_ context.Context, _ []agent.Message, _ map[string]interface{}) (*agent.GenerateResult, error) {
	out := pick(f.curC, f.cursor)
	f.cursor++
	return &agent.GenerateResult{Content: out}, nil
}

// ---- tasks + per-dialect fixtures ----

var evalAddTool = agent.ToolSchema{
	Name:        "add",
	Description: "Add two numbers",
	InputSchema: map[string]interface{}{"type": "object", "properties": map[string]interface{}{"a": map[string]interface{}{"type": "number"}, "b": map[string]interface{}{"type": "number"}}, "required": []interface{}{"a", "b"}},
}

var sampleTasks = []EvalTask{
	{ID: "weather-valid", Prompt: "weather in Paris?", Tools: []agent.ToolSchema{weatherTool}, ExpectTool: "get_weather", ExpectArgs: func(a map[string]interface{}) bool { return a["city"] == "Paris" }},
	{ID: "add-valid", Prompt: "add 2 and 3", Tools: []agent.ToolSchema{evalAddTool}, ExpectTool: "add"},
	{ID: "final-answer", Prompt: "say hi", Tools: []agent.ToolSchema{weatherTool}},
	{ID: "repair-unknown", Prompt: "weather in Rome?", Tools: []agent.ToolSchema{weatherTool}, ExpectTool: "get_weather"},
	{ID: "malformed-hard", Prompt: "weather in Oslo?", Tools: []agent.ToolSchema{weatherTool}, ExpectTool: "get_weather"},
}

func mustJSON(v interface{}) string { b, _ := json.Marshal(v); return string(b) }
func call(name string, args map[string]interface{}) map[string]interface{} {
	return map[string]interface{}{"name": name, "arguments": args}
}
func hermesFix(o interface{}) string { return "<tool_call>\n" + mustJSON(o) + "\n</tool_call>" }
func jsonFix(o interface{}) string   { return tcFence + "tool_call\n" + mustJSON(o) + "\n" + tcFence }

var hermesFixtures = map[string][]string{
	"weather-valid":  {hermesFix(call("get_weather", map[string]interface{}{"city": "Paris"}))},
	"add-valid":      {hermesFix(call("add", map[string]interface{}{"a": 2, "b": 3}))},
	"final-answer":   {"Hello"},
	"repair-unknown": {hermesFix(call("fetch_forecast", map[string]interface{}{"city": "Rome"})), hermesFix(call("get_weather", map[string]interface{}{"city": "Rome"}))},
	"malformed-hard": {"<tool_call>\n{bad json\n</tool_call>", "<tool_call>\n{still bad\n</tool_call>", "<tool_call>\n{nope\n</tool_call>"},
}

var jsonFixtures = map[string][]string{
	"weather-valid":  {jsonFix(call("get_weather", map[string]interface{}{"city": "Paris"}))},
	"add-valid":      {jsonFix(call("add", map[string]interface{}{"a": 2, "b": 3}))},
	"final-answer":   {"Hello"},
	"repair-unknown": {jsonFix(call("fetch_forecast", map[string]interface{}{"city": "Rome"})), jsonFix(call("get_weather", map[string]interface{}{"city": "Rome"}))},
	"malformed-hard": {tcFence + "tool_call\n{bad json\n" + tcFence, tcFence + "tool_call\n{still bad\n" + tcFence, tcFence + "tool_call\n{nope\n" + tcFence},
}

var reactFixtures = map[string][]string{
	"weather-valid":  {"Thought: check.\nAction: get_weather\nAction Input: {\"city\": \"Paris\"}"},
	"add-valid":      {"Thought: add.\nAction: add\nAction Input: {\"a\": 2, \"b\": 3}"},
	"final-answer":   {"Thought: greet.\nFinal Answer: Hello"},
	"repair-unknown": {"Action: fetch_forecast\nAction Input: {\"city\": \"Rome\"}", "Action: get_weather\nAction Input: {\"city\": \"Rome\"}"},
	"malformed-hard": {"Action: get_weather\nAction Input: {bad", "Action: get_weather\nAction Input: {bad", "Action: get_weather\nAction Input: {bad"},
}

var constrainedFixtures = map[string][]string{
	"weather-valid":  {mustJSON(map[string]interface{}{"tool_calls": []interface{}{call("get_weather", map[string]interface{}{"city": "Paris"})}})},
	"add-valid":      {mustJSON(map[string]interface{}{"tool_calls": []interface{}{call("add", map[string]interface{}{"a": 2, "b": 3})}})},
	"final-answer":   {mustJSON(map[string]interface{}{"content": "Hello"})},
	"repair-unknown": {mustJSON(map[string]interface{}{"tool_calls": []interface{}{call("get_weather", map[string]interface{}{"city": "Rome"})}})},
	"malformed-hard": {mustJSON(map[string]interface{}{"tool_calls": []interface{}{call("get_weather", map[string]interface{}{"city": "Oslo"})}})},
}

func mkEntry(label, model string, fixtures map[string][]string, config Config) EvalMatrixEntry {
	return EvalMatrixEntry{
		Label: label,
		Make: func() (agent.Provider, string, func(string)) {
			p := &fixtureProvider{prompted: fixtures, constrained: constrainedFixtures}
			return p, model, p.setTask
		},
		Config: config,
	}
}

func TestEvalMatrix(t *testing.T) {
	matrix := []EvalMatrixEntry{
		mkEntry("qwen2.5-coder:7b (hermes)", "qwen2.5-coder:7b", hermesFixtures, Config{}),
		mkEntry("llama-3.1-8b (json)", "llama-3.1-8b", jsonFixtures, Config{}),
		mkEntry("phi-3-mini (react)", "phi-3-mini", reactFixtures, Config{}),
		mkEntry("qwen2.5 (constrained)", "qwen2.5-coder:7b", hermesFixtures, Config{Mode: "constrained"}),
	}
	reports := RunMatrix(matrix, sampleTasks)
	t.Log("\n" + FormatMatrix(reports))

	if len(reports) != len(matrix) {
		t.Fatalf("expected %d reports, got %d", len(matrix), len(reports))
	}
	var constrained *EvalReport
	for i := range reports {
		if r := reports[i]; r.TaskMatchRate < 0.6 {
			t.Errorf("%s task-match %.2f < 0.6", r.Label, r.TaskMatchRate)
		}
		if strings.Contains(reports[i].Label, "constrained") {
			constrained = &reports[i]
		}
	}
	if constrained == nil {
		t.Fatal("no constrained row")
	}
	for i := range reports {
		if !strings.Contains(reports[i].Label, "constrained") && constrained.SchemaValidRate < reports[i].SchemaValidRate {
			t.Errorf("constrained schema-valid %.2f < %s %.2f", constrained.SchemaValidRate, reports[i].Label, reports[i].SchemaValidRate)
		}
	}
}

// ---- ReAct dialect ----

func TestReactParse(t *testing.T) {
	r := ReactDialect.Parse("Thought: check.\nAction: get_weather\nAction Input: {\"city\": \"Paris\"}", nil)
	if len(r.ToolCalls) != 1 || r.ToolCalls[0].Name != "get_weather" || r.ToolCalls[0].Arguments["city"] != "Paris" {
		t.Fatalf("unexpected react parse: %+v", r)
	}
	f := ReactDialect.Parse("Thought: done.\nFinal Answer: It is sunny.", nil)
	if len(f.ToolCalls) != 0 || f.Content != "It is sunny." {
		t.Fatalf("expected final answer, got %+v", f)
	}
	m := ReactDialect.Parse("Action: get_weather\nAction Input: {bad", nil)
	if len(m.ToolCalls) != 0 || len(m.Malformed) == 0 {
		t.Fatalf("expected malformed, got %+v", m)
	}
}

// ---- GBNF ----

func TestGBNF(t *testing.T) {
	g, err := JSONSchemaToGBNF(BuildEnvelopeSchema([]agent.ToolSchema{weatherTool, evalAddTool}))
	if err != nil {
		t.Fatal(err)
	}
	for _, frag := range []string{"root ::=", "string ::=", "number ::=", `\"get_weather\"`, `\"add\"`} {
		if !strings.Contains(g, frag) {
			t.Errorf("GBNF missing %q\n%s", frag, g)
		}
	}
	if _, err := JSONSchemaToGBNF(map[string]interface{}{"$ref": "#/x"}); err == nil {
		t.Fatal("expected GBNFUnsupportedError for $ref")
	}
}

// ---- constrained provider path ----

func TestConstrainedProviderPath(t *testing.T) {
	fp := &fixtureProvider{
		prompted:    map[string][]string{"x": {""}},
		constrained: map[string][]string{"x": {mustJSON(map[string]interface{}{"tool_calls": []interface{}{call("get_weather", map[string]interface{}{"city": "Paris"})}})}},
	}
	fp.setTask("x")
	bp := Bootstrap(fp, "qwen2.5-coder:7b", Config{Mode: "constrained"})
	res, err := bp.Generate(context.Background(), []agent.Message{{Role: "user", Content: "?"}}, []agent.ToolSchema{weatherTool})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.ToolCalls) != 1 || res.ToolCalls[0].Name != "get_weather" || res.ToolCalls[0].Arguments["city"] != "Paris" {
		t.Fatalf("expected constrained get_weather call, got %+v", res.ToolCalls)
	}
}
