package atlas

import (
	"context"
	"errors"
	"testing"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/mcp"
	atlastools "gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/tools"
)

type fakeMCPCaller struct {
	server string
	tool   string
	args   map[string]interface{}
	result *mcp.ToolResult
	err    error
}

func (f *fakeMCPCaller) CallTool(_ context.Context, server, tool string, args map[string]interface{}) (*mcp.ToolResult, error) {
	f.server, f.tool, f.args = server, tool, args
	return f.result, f.err
}

func TestAtlasConfigurationToolsAndErrorPaths(t *testing.T) {
	t.Parallel()
	config := &Config{SystemPrompt: "system"}
	atlas := New(config)
	if config.MaxSteps != 10 || config.Temperature != 0.7 {
		t.Fatalf("defaults not applied: %#v", config)
	}
	state := atlas.GetState()
	if state.MessageCount != 1 || state.IsInitialized {
		t.Fatalf("unexpected state: %#v", state)
	}

	tool := atlastools.Tool{
		Name: "echo",
		Handler: func(context.Context, map[string]interface{}, atlastools.Context) (interface{}, error) {
			return "ok", nil
		},
	}
	if err := atlas.RegisterTool(tool); err != nil {
		t.Fatal(err)
	}
	if _, ok := atlas.GetTool("echo"); !ok || len(atlas.ListTools()) != 1 {
		t.Fatal("tool registration failed")
	}

	ctx := context.Background()
	if err := atlas.Initialize(ctx); err == nil {
		t.Fatal("initialization without provider should fail")
	}
	if _, err := atlas.Execute(ctx, ExecuteOptions{}); err == nil {
		t.Fatal("execution without provider should fail")
	}
	atlas.ClearHistory()
	if atlas.GetState().MessageCount != 1 {
		t.Fatal("system prompt should survive clear")
	}
	if err := atlas.Destroy(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestNewAcceptsNilConfiguration(t *testing.T) {
	if got := New(nil); got == nil || got.config == nil {
		t.Fatal("nil configuration should use safe defaults")
	}
}

func TestMCPToolAdapterPreservesSchemaRoutingAndErrors(t *testing.T) {
	caller := &fakeMCPCaller{result: &mcp.ToolResult{Content: []mcp.ContentBlock{mcp.TextContent{Type: "text", Text: "ok"}}}}
	tool := adaptMCPTool("search-server", "search__lookup", mcp.Tool{
		Name: "lookup", Description: "Look up an item",
		InputSchema: mcp.InputSchema{
			Type: "object", Required: []string{"query"},
			Properties: map[string]mcp.PropertyDef{"query": {Type: "string"}},
		},
	}, caller)
	if tool.Name != "search__lookup" || tool.InputSchema["type"] != "object" {
		t.Fatalf("unexpected tool projection: %#v", tool)
	}
	result, err := tool.Handler(context.Background(), map[string]interface{}{"query": "atlas"}, atlastools.Context{})
	if err != nil || result == nil || caller.server != "search-server" || caller.tool != "lookup" {
		t.Fatalf("MCP routing failed: result=%#v err=%v caller=%#v", result, err, caller)
	}

	caller.err = errors.New("transport down")
	if _, err := tool.Handler(context.Background(), nil, atlastools.Context{}); err == nil {
		t.Fatal("transport errors must propagate")
	}
	caller.err = nil
	caller.result = &mcp.ToolResult{IsError: true}
	if _, err := tool.Handler(context.Background(), nil, atlastools.Context{}); err == nil {
		t.Fatal("MCP error results must fail the tool call")
	}
}
