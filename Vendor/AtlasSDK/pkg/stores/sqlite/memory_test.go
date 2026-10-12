package sqlite

import (
	"context"
	"maps"
	"sync"
	"testing"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
)

func newTestMemoryStore(t *testing.T) *MemoryStore {
	t.Helper()
	ms, err := NewMemoryStore(stores.StoreConfig{URL: ":memory:"})
	if err != nil {
		t.Fatalf("NewMemoryStore: %v", err)
	}
	store := ms.(*MemoryStore)
	if err := store.Init(context.Background()); err != nil {
		t.Fatalf("Init: %v", err)
	}
	t.Cleanup(func() { store.Close(context.Background()) })
	return store
}

func TestMemoryStore_SaveAndGet(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	entry := stores.StoredMemoryEntry{
		Content: "Go is a compiled language",
		Level:   stores.MemoryLevelProject,
		Source:  "test",
		Tags:    []string{"go", "programming"},
	}

	id, err := store.Save(ctx, entry)
	if err != nil {
		t.Fatalf("Save: %v", err)
	}
	if id == "" {
		t.Fatal("expected non-empty ID")
	}

	got, err := store.Get(ctx, id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Content != entry.Content {
		t.Errorf("expected content %q, got %q", entry.Content, got.Content)
	}
	if got.Level != stores.MemoryLevelProject {
		t.Errorf("expected level %q, got %q", stores.MemoryLevelProject, got.Level)
	}
	if len(got.Tags) != 2 {
		t.Errorf("expected 2 tags, got %d", len(got.Tags))
	}
	if got.CreatedAt == 0 {
		t.Error("expected non-zero CreatedAt")
	}
}

func TestMemoryStore_SaveWithCustomID(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	entry := stores.StoredMemoryEntry{
		ID:      "custom-id-1",
		Content: "Custom ID entry",
		Level:   stores.MemoryLevelUser,
		Source:  "test",
	}

	id, err := store.Save(ctx, entry)
	if err != nil {
		t.Fatalf("Save: %v", err)
	}
	if id != "custom-id-1" {
		t.Errorf("expected ID 'custom-id-1', got %q", id)
	}

	got, err := store.Get(ctx, "custom-id-1")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Content != "Custom ID entry" {
		t.Errorf("unexpected content: %q", got.Content)
	}
}

func TestMemoryStore_SavePreservesPortableTimestampsAndRecordsMigrations(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	id, err := store.Save(ctx, stores.StoredMemoryEntry{
		Content:   "portable",
		Level:     stores.MemoryLevelProject,
		Source:    "import",
		CreatedAt: 123,
		UpdatedAt: 456,
	})
	if err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := store.Get(ctx, id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.CreatedAt != 123 || got.UpdatedAt != 456 {
		t.Fatalf("expected timestamps 123/456, got %d/%d", got.CreatedAt, got.UpdatedAt)
	}

	var migrations int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM memory_schema_migrations`).Scan(&migrations); err != nil {
		t.Fatalf("read migrations: %v", err)
	}
	if migrations != 3 {
		t.Fatalf("expected 3 recorded migrations, got %d", migrations)
	}
}

func TestMemoryStore_GetNotFound(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	_, err := store.Get(ctx, "nonexistent")
	if err == nil {
		t.Fatal("expected error for nonexistent entry")
	}
}

func TestMemoryStore_Update(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	id, _ := store.Save(ctx, stores.StoredMemoryEntry{
		Content: "original",
		Level:   stores.MemoryLevelUser,
		Source:  "test",
	})

	// Brief pause so updated_at differs.
	time.Sleep(2 * time.Millisecond)

	err := store.Update(ctx, id, stores.StoredMemoryEntry{
		Content: "updated content",
		Tags:    []string{"new-tag"},
	})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := store.Get(ctx, id)
	if err != nil {
		t.Fatalf("Get after update: %v", err)
	}
	if got.Content != "updated content" {
		t.Errorf("expected updated content, got %q", got.Content)
	}
	// Level should remain unchanged since we passed zero-value.
	if got.Level != stores.MemoryLevelUser {
		t.Errorf("expected level to remain 'user', got %q", got.Level)
	}
	if len(got.Tags) != 1 || got.Tags[0] != "new-tag" {
		t.Errorf("expected tags [new-tag], got %v", got.Tags)
	}
}

func TestMemoryStore_UpdateNotFound(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	err := store.Update(ctx, "nonexistent", stores.StoredMemoryEntry{Content: "x"})
	if err == nil {
		t.Fatal("expected error updating nonexistent entry")
	}
}

func TestMemoryStore_CompareAndSwapAllowsOneConcurrentWriter(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()
	id, err := store.Save(ctx, stores.StoredMemoryEntry{
		Content: "base", Level: stores.MemoryLevelSession, Source: "test", CreatedAt: 1, UpdatedAt: 1,
	})
	if err != nil {
		t.Fatal(err)
	}

	results := make(chan bool, 2)
	errors := make(chan error, 2)
	var wg sync.WaitGroup
	for index, content := range []string{"writer-a", "writer-b"} {
		wg.Add(1)
		go func(version int64, value string) {
			defer wg.Done()
			swapped, swapErr := store.CompareAndSwap(ctx, id, 1, stores.StoredMemoryEntry{Content: value, UpdatedAt: version})
			results <- swapped
			errors <- swapErr
		}(int64(index+2), content)
	}
	wg.Wait()
	close(results)
	close(errors)

	winners := 0
	for swapped := range results {
		if swapped {
			winners++
		}
	}
	for swapErr := range errors {
		if swapErr != nil {
			t.Fatal(swapErr)
		}
	}
	if winners != 1 {
		t.Fatalf("expected exactly one CAS winner, got %d", winners)
	}
	if swapped, err := store.CompareAndSwap(ctx, id, 1, stores.StoredMemoryEntry{Content: "stale", UpdatedAt: 4}); err != nil || swapped {
		t.Fatalf("stale CAS should fail without error: swapped=%v err=%v", swapped, err)
	}
}

func TestMemoryStore_Delete(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	id, _ := store.Save(ctx, stores.StoredMemoryEntry{
		Content: "to delete",
		Level:   stores.MemoryLevelSession,
		Source:  "test",
	})

	if err := store.Delete(ctx, id); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	_, err := store.Get(ctx, id)
	if err == nil {
		t.Fatal("expected error getting deleted entry")
	}
}

func TestMemoryStore_DeleteNotFound(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	err := store.Delete(ctx, "nonexistent")
	if err == nil {
		t.Fatal("expected error deleting nonexistent entry")
	}
}

func TestMemoryStore_GetByLevel(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	store.Save(ctx, stores.StoredMemoryEntry{Content: "user1", Level: stores.MemoryLevelUser, Source: "test"})
	store.Save(ctx, stores.StoredMemoryEntry{Content: "project1", Level: stores.MemoryLevelProject, Source: "test"})
	store.Save(ctx, stores.StoredMemoryEntry{Content: "user2", Level: stores.MemoryLevelUser, Source: "test"})

	entries, err := store.GetByLevel(ctx, stores.MemoryLevelUser)
	if err != nil {
		t.Fatalf("GetByLevel: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 user-level entries, got %d", len(entries))
	}
	for _, e := range entries {
		if e.Level != stores.MemoryLevelUser {
			t.Errorf("expected level 'user', got %q", e.Level)
		}
	}
}

func TestMemoryStore_Search(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	store.Save(ctx, stores.StoredMemoryEntry{Content: "Go is a compiled language", Level: stores.MemoryLevelProject, Source: "test", Tags: []string{"go"}})
	store.Save(ctx, stores.StoredMemoryEntry{Content: "Python is an interpreted language", Level: stores.MemoryLevelProject, Source: "test", Tags: []string{"python"}})
	store.Save(ctx, stores.StoredMemoryEntry{Content: "Go routines enable concurrency", Level: stores.MemoryLevelUser, Source: "test", Tags: []string{"go"}})

	// Basic search.
	results, err := store.Search(ctx, "Go", nil)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}

	// Search with level filter.
	results, err = store.Search(ctx, "Go", &stores.MemorySearchOptions{Level: stores.MemoryLevelProject})
	if err != nil {
		t.Fatalf("Search with level: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result with project level, got %d", len(results))
	}

	// Search with tag filter.
	results, err = store.Search(ctx, "language", &stores.MemorySearchOptions{Tags: []string{"python"}})
	if err != nil {
		t.Fatalf("Search with tags: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result with python tag, got %d", len(results))
	}
}

func TestMemoryStore_SearchFiltersExpiryAndPreservesLegalHold(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()
	now := int64(2_000)
	baseMetadata := map[string]interface{}{"tenantId": "tenant-a", "namespace": "default"}

	expired := maps.Clone(baseMetadata)
	expired["retention"] = map[string]interface{}{"expiresAt": int64(1_500), "legalHold": false}
	held := maps.Clone(baseMetadata)
	held["retention"] = map[string]interface{}{"expiresAt": int64(1_500), "legalHold": true}
	active := maps.Clone(baseMetadata)
	active["retention"] = map[string]interface{}{"expiresAt": int64(2_500), "legalHold": false}

	for _, metadata := range []map[string]interface{}{expired, held, active} {
		if _, err := store.Save(ctx, stores.StoredMemoryEntry{Content: "retained", Level: stores.MemoryLevelProject, Source: "test", Metadata: metadata}); err != nil {
			t.Fatal(err)
		}
	}

	results, err := store.Search(ctx, "retained", &stores.MemorySearchOptions{TenantID: "tenant-a", Namespace: "default", Now: now})
	if err != nil || len(results) != 2 {
		t.Fatalf("expected active and held records, got %d: %v", len(results), err)
	}
	results, err = store.Search(ctx, "retained", &stores.MemorySearchOptions{TenantID: "tenant-a", Namespace: "default", Now: now, IncludeExpired: true})
	if err != nil || len(results) != 3 {
		t.Fatalf("expected all records when expiry is disabled, got %d: %v", len(results), err)
	}
}

func TestMemoryStore_LoadAll(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	store.Save(ctx, stores.StoredMemoryEntry{Content: "entry1", Level: stores.MemoryLevelUser, Source: "test"})
	store.Save(ctx, stores.StoredMemoryEntry{Content: "entry2", Level: stores.MemoryLevelProject, Source: "test"})

	entries, err := store.LoadAll(ctx)
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
}

func TestMemoryStore_GetSystemPrompt(t *testing.T) {
	store := newTestMemoryStore(t)
	ctx := context.Background()

	// Empty store.
	prompt, err := store.GetSystemPrompt(ctx)
	if err != nil {
		t.Fatalf("GetSystemPrompt: %v", err)
	}
	if prompt != "" {
		t.Errorf("expected empty prompt from empty store, got %q", prompt)
	}

	// With entries.
	store.Save(ctx, stores.StoredMemoryEntry{Content: "Always use Go modules", Level: stores.MemoryLevelProject, Source: "test"})
	store.Save(ctx, stores.StoredMemoryEntry{Content: "User prefers dark mode", Level: stores.MemoryLevelUser, Source: "test"})

	prompt, err = store.GetSystemPrompt(ctx)
	if err != nil {
		t.Fatalf("GetSystemPrompt: %v", err)
	}
	if prompt == "" {
		t.Error("expected non-empty prompt")
	}
	if !contains(prompt, "Always use Go modules") {
		t.Error("expected prompt to contain 'Always use Go modules'")
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsSubstr(s, substr))
}

func containsSubstr(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// Verify MemoryStore satisfies the interface at compile time.
var _ stores.MemoryStore = (*MemoryStore)(nil)
