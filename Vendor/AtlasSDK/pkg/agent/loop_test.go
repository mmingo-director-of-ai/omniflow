package agent

import (
	"context"
	"testing"
)

type sequenceProvider struct{ calls int }

func (p *sequenceProvider) Generate(_ context.Context, _ []Message, tools []ToolSchema) (*GenerateResult, error) {
	p.calls++
	if p.calls == 1 {
		return &GenerateResult{
			Content:    "calling",
			ToolCalls:  []ToolCallData{{ID: "call-1", Name: "read_item", Arguments: map[string]interface{}{"id": "1"}}},
			TokensUsed: 2,
		}, nil
	}
	return &GenerateResult{Content: "done", TokensUsed: 1}, nil
}

type testTool struct{}

func (testTool) Name() string                        { return "read_item" }
func (testTool) Description() string                 { return "Read an item" }
func (testTool) InputSchema() map[string]interface{} { return map[string]interface{}{"type": "object"} }
func (testTool) Execute(context.Context, map[string]interface{}) (interface{}, error) {
	return "value", nil
}

func TestAgentLoopExecutesToolAndStops(t *testing.T) {
	t.Parallel()
	provider := &sequenceProvider{}
	loop := NewAgentLoop(provider, map[string]Tool{"read_item": testTool{}}, AgentLoopConfig{MaxSteps: 3})
	result, err := loop.Execute(context.Background(), "work", nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.Text != "done" || result.FinishReason != StopConditionStop || len(result.ToolCalls) != 1 || !result.ToolCalls[0].Success {
		t.Fatalf("unexpected result: %#v", result)
	}
	if result.State.TotalTokens != 3 || len(result.Steps) != 2 {
		t.Fatalf("unexpected state: %#v", result.State)
	}
}
