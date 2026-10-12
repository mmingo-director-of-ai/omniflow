package subagent

import (
	"context"
	"errors"
	"strings"
	"testing"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/tools"
)

type fakeExecutor struct {
	registered []tools.Tool
	destroyed  bool
}

func (f *fakeExecutor) Initialize(context.Context) error { return nil }
func (f *fakeExecutor) RegisterTool(tool tools.Tool) error {
	f.registered = append(f.registered, tool)
	return nil
}
func (f *fakeExecutor) RegisterTools(toolsList []tools.Tool) error {
	f.registered = append(f.registered, toolsList...)
	return nil
}
func (f *fakeExecutor) Execute(_ context.Context, messages []Message, onToolCall func(string, map[string]interface{})) (*ExecutionResult, error) {
	if !strings.Contains(messages[0].Content, "Task:\nwork") {
		return nil, errors.New("context missing")
	}
	onToolCall("search", map[string]interface{}{"q": "atlas"})
	return &ExecutionResult{Text: "done", Steps: []Step{{Step: 1, Role: "assistant", Content: "done"}}}, nil
}
func (f *fakeExecutor) Destroy(context.Context) error { f.destroyed = true; return nil }

func TestRunnerLifecycleAndExecution(t *testing.T) {
	t.Parallel()
	runner := NewRunner(&AtlasConfig{Provider: "test"})
	if err := runner.RegisterTool(tools.Tool{Name: "search", Handler: func(context.Context, map[string]interface{}, tools.Context) (interface{}, error) { return "ok", nil }}); err != nil {
		t.Fatal(err)
	}
	agent := &Config{Name: "worker", Type: SubAgentTypeExplore, Tools: []string{"search"}}
	if err := runner.RegisterAgent(agent); err != nil || agent.MaxTurns != 10 {
		t.Fatalf("register failed: %v %#v", err, agent)
	}
	if err := runner.RegisterAgent(&Config{}); err == nil {
		t.Fatal("empty name should fail")
	}
	if _, ok := runner.GetAgent("worker"); !ok || len(runner.ListAgents()) != 1 || len(runner.GetTools()) != 1 {
		t.Fatal("runner registry mismatch")
	}

	executor := &fakeExecutor{}
	runner.SetAtlasFactory(func(*AtlasConfig) (AtlasExecutor, error) { return executor, nil })
	var started, called, completed bool
	result, err := runner.Execute(context.Background(), agent, ExecuteOptions{
		Prompt:  "work",
		Context: map[string]interface{}{"tenant": "test"},
		Callbacks: &Callbacks{
			OnStart:    func(string) { started = true },
			OnToolCall: func(string, string, map[string]interface{}) { called = true },
			OnComplete: func(string, Result) { completed = true },
		},
	})
	if err != nil || !result.Success || result.Output != "done" || !started || !called || !completed || !executor.destroyed {
		t.Fatalf("execution failed: %#v %v", result, err)
	}

	data, err := runner.ToJSON()
	if err != nil {
		t.Fatal(err)
	}
	restored := NewSubAgentRunner(&AtlasConfig{})
	if err := restored.FromJSON(data); err != nil {
		t.Fatal(err)
	}
	if _, ok := restored.GetAgent("worker"); !ok || !restored.RemoveAgent("worker") {
		t.Fatal("JSON round trip failed")
	}
	if _, err := restored.ExecuteParallel(context.Background(), nil, ExecuteOptions{}); err == nil {
		t.Fatal("empty parallel batch should fail")
	}
	if CreateExploreAgent("e", "").Type != SubAgentTypeExplore || CreatePlanAgent("p", "").Type != SubAgentTypePlan || CreateGeneralAgent("g", "").Type != SubAgentTypeGeneral {
		t.Fatal("agent factories mismatch")
	}
}
