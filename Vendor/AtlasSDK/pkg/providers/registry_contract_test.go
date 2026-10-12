package providers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRegistryOrderingAndLifecycle(t *testing.T) {
	t.Parallel()
	registry := NewProviderRegistry()
	if registry.GetPrimary() != nil {
		t.Fatal("empty registry should not have a primary")
	}
	if _, err := registry.GetAvailable(context.Background()); err == nil {
		t.Fatal("empty registry should not have an available provider")
	}

	first := registry.Register(ProviderConfig{Type: ProviderOpenAI, Model: "first", BaseURL: "http://invalid"})
	priority := registry.Register(ProviderConfig{Type: ProviderAnthropic, Model: "priority", BaseURL: "http://invalid", Priority: 1})
	if registry.GetPrimary() != priority {
		t.Fatal("priority provider not selected")
	}
	if got, ok := registry.Get(ProviderOpenAI); !ok || got != first {
		t.Fatal("provider lookup failed")
	}
	if len(registry.List()) != 2 {
		t.Fatal("provider list mismatch")
	}
	if err := registry.Destroy(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(registry.List()) != 0 {
		t.Fatal("destroy did not clear registry")
	}
}

func TestOpenAIProviderHTTPContract(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/models":
			w.WriteHeader(http.StatusOK)
		case "/chat/completions":
			if r.Header.Get("Authorization") != "Bearer token" {
				t.Errorf("authorization header missing")
			}
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"choices": []interface{}{map[string]interface{}{
					"message": map[string]interface{}{
						"content": "done",
						"tool_calls": []interface{}{map[string]interface{}{
							"id":       "call-1",
							"function": map[string]interface{}{"name": "search", "arguments": `{"q":"atlas"}`},
						}},
					},
					"finish_reason": "stop",
				}},
				"usage": map[string]interface{}{"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	provider := NewOpenAIProvider("model", "token", server.URL)
	ctx := context.Background()
	if !provider.IsAvailable(ctx) || provider.Initialize(ctx) != nil {
		t.Fatal("provider should be available")
	}
	response, err := provider.Generate(ctx, GenerateOptions{
		Messages: []Message{{Role: "user", Content: "go"}},
		Tools:    []Tool{{Name: "search", Description: "search", InputSchema: map[string]interface{}{"type": "object"}}},
	})
	if err != nil || response.Content != "done" || len(response.ToolCalls) != 1 || response.Usage.TotalTokens != 3 {
		t.Fatalf("unexpected response: %#v, %v", response, err)
	}
	var chunks []StreamChunk
	if _, err := provider.GenerateStream(ctx, GenerateOptions{}, func(chunk StreamChunk) { chunks = append(chunks, chunk) }); err != nil || len(chunks) != 2 {
		t.Fatalf("stream contract failed: %#v, %v", chunks, err)
	}
	if provider.ID() == "" || provider.Type() != ProviderOpenAI || provider.Model() != "model" || !provider.Capabilities().SupportsTools {
		t.Fatal("provider metadata mismatch")
	}
}
