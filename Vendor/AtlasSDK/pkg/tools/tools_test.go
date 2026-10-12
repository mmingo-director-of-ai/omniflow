package tools

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestRegistryLifecycleAndExecution(t *testing.T) {
	t.Parallel()
	registry := NewRegistry()
	if err := registry.Register(Tool{}); err == nil {
		t.Fatal("expected empty name to fail")
	}
	if err := registry.Register(Tool{Name: "missing-handler"}); err == nil {
		t.Fatal("expected missing handler to fail")
	}

	echo := Tool{
		Name:        "echo",
		Description: "Echo a value",
		InputSchema: map[string]interface{}{"type": "object"},
		Handler: func(_ context.Context, args map[string]interface{}, toolCtx Context) (interface{}, error) {
			if toolCtx.ToolName != "echo" || toolCtx.Atlas != "atlas" {
				t.Fatalf("unexpected tool context: %#v", toolCtx)
			}
			return args["value"], nil
		},
	}
	failing := Tool{
		Name: "fail",
		Handler: func(context.Context, map[string]interface{}, Context) (interface{}, error) {
			return nil, errors.New("boom")
		},
	}
	if err := registry.RegisterMultiple([]Tool{echo, failing}); err != nil {
		t.Fatalf("register tools: %v", err)
	}
	if err := registry.Register(echo); err == nil {
		t.Fatal("duplicate tool registration should fail")
	}
	if _, ok := registry.Get("echo"); !ok {
		t.Fatal("registered tool missing")
	}
	if len(registry.List()) != 2 || len(registry.ListNames()) != 2 {
		t.Fatal("unexpected tool list")
	}

	result, err := registry.Execute(context.Background(), "echo", map[string]interface{}{"value": "ok"}, "atlas")
	if err != nil || !result.Success || result.Data != "ok" {
		t.Fatalf("unexpected execute result: %#v, %v", result, err)
	}
	missing, _ := registry.Execute(context.Background(), "unknown", nil, nil)
	if missing.Success || !strings.Contains(missing.Error, "not found") {
		t.Fatalf("unexpected missing result: %#v", missing)
	}
	failed, _ := registry.Execute(context.Background(), "fail", nil, nil)
	if failed.Success || failed.Error != "boom" {
		t.Fatalf("unexpected failure result: %#v", failed)
	}

	jsonResult := registry.ExecuteJSON(context.Background(), "echo", []byte(`{"value":"json"}`), "atlas")
	if !jsonResult.Success || string(jsonResult.Result) != `"json"` {
		t.Fatalf("unexpected JSON result: %#v", jsonResult)
	}
	if registry.ExecuteJSON(context.Background(), "echo", []byte(`{`), nil).Success {
		t.Fatal("invalid JSON should fail")
	}
	if len(registry.ToProviderTools()) != 2 {
		t.Fatal("provider conversion omitted tools")
	}

	registry.Remove("fail")
	if len(registry.List()) != 1 {
		t.Fatal("remove failed")
	}
	registry.Clear()
	if len(registry.List()) != 0 {
		t.Fatal("clear failed")
	}
}
