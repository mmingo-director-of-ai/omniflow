package embeddings

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestMemoryVectorStoreLifecycle(t *testing.T) {
	t.Parallel()
	store := NewMemoryVectorStore()
	store.Add("a", LevelProject, "ATLAS.md", "alpha", &EmbeddingVector{Values: []float64{1, 0}, Model: "test"})
	store.Add("b", LevelUser, "user.md", strings.Repeat("b", 220), &EmbeddingVector{Values: []float64{0, 1}, Model: "test"})
	if len(store.GetAll()) != 2 || len(store.GetByLevel(LevelProject)) != 1 {
		t.Fatal("stored vectors missing")
	}
	results := store.Search([]float64{1, 0}, SearchOptions{})
	if len(results) != 1 || results[0].ID != "a" || results[0].Score != 1 {
		t.Fatalf("unexpected search results: %#v", results)
	}
	user := store.Search([]float64{0, 1}, SearchOptions{Level: LevelUser, Threshold: 0.1})
	if len(user) != 1 || len(user[0].Snippet) != 203 {
		t.Fatalf("unexpected user result: %#v", user)
	}
	if mismatch := store.Search([]float64{1, 0, 0}, SearchOptions{}); len(mismatch) != 0 {
		t.Fatal("dimension mismatch should not match")
	}
	count, levels := store.Stats()
	if count != 2 || levels[LevelProject] != 1 || levels[LevelUser] != 1 {
		t.Fatalf("unexpected stats: %d %#v", count, levels)
	}
	store.Remove("a")
	store.Clear()
	if len(store.GetAll()) != 0 {
		t.Fatal("clear failed")
	}
}

func TestOllamaProviderHTTPContract(t *testing.T) {
	t.Parallel()
	var embedCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/version":
			w.WriteHeader(http.StatusOK)
		case "/api/embeddings":
			embedCalls.Add(1)
			var request map[string]interface{}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Errorf("decode request: %v", err)
			}
			if request["model"] != "test-model" {
				t.Errorf("unexpected model: %#v", request)
			}
			_ = json.NewEncoder(w).Encode(map[string]interface{}{"embedding": []float64{1, 2}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	provider := NewOllamaProvider(ProviderConfig{BaseURL: server.URL, Model: "test-model", Timeout: 1000})
	if provider.Name() != "ollama" || provider.DefaultModel() != "nomic-embed-text" {
		t.Fatal("provider identity mismatch")
	}
	if !provider.IsAvailable(context.Background()) {
		t.Fatal("provider should be available")
	}
	vector, err := provider.Embed(context.Background(), "hello")
	if err != nil || len(vector.Values) != 2 || vector.Model != "test-model" {
		t.Fatalf("embed failed: %#v, %v", vector, err)
	}
	batch, err := provider.EmbedBatch(context.Background(), []string{"a", "b"})
	if err != nil || len(batch) != 2 || embedCalls.Load() != 3 {
		t.Fatalf("batch failed: %d, %v", len(batch), err)
	}

	provider.SetModel("changed")
	provider.SetBaseURL(server.URL + "/missing")
	if provider.IsAvailable(context.Background()) {
		t.Fatal("missing endpoint should be unavailable")
	}
}
