package sqlite

import (
	"context"
	"testing"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
)

func newTestContextStore(t *testing.T) *ContextStore {
	t.Helper()
	cs, err := NewContextStore(stores.StoreConfig{URL: ":memory:"})
	if err != nil {
		t.Fatalf("NewContextStore: %v", err)
	}
	store := cs.(*ContextStore)
	if err := store.Init(context.Background()); err != nil {
		t.Fatalf("Init: %v", err)
	}
	t.Cleanup(func() { store.Close(context.Background()) })
	return store
}

func TestContextStore_CreateAndDestroySession(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	if err := store.CreateSession(ctx, "s1", &stores.SessionMetadata{Label: "test"}); err != nil {
		t.Fatalf("CreateSession: %v", err)
	}

	// Duplicate should fail.
	if err := store.CreateSession(ctx, "s1", nil); err == nil {
		t.Fatal("expected error creating duplicate session")
	}

	if err := store.DestroySession(ctx, "s1"); err != nil {
		t.Fatalf("DestroySession: %v", err)
	}

	// Destroying non-existent session should fail.
	if err := store.DestroySession(ctx, "s1"); err == nil {
		t.Fatal("expected error destroying non-existent session")
	}
}

func TestContextStore_AppendAndGetMessages(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)

	msgs := []stores.Message{
		{Role: "user", Content: "Hello"},
		{Role: "assistant", Content: "Hi there!"},
		{Role: "user", Content: "How are you?"},
	}

	for _, m := range msgs {
		if err := store.Append(ctx, "s1", m); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}

	got, err := store.GetMessages(ctx, "s1", nil)
	if err != nil {
		t.Fatalf("GetMessages: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 messages, got %d", len(got))
	}
	if got[0].Content != "Hello" {
		t.Errorf("expected first message content 'Hello', got %q", got[0].Content)
	}

	// Test with limit.
	got, err = store.GetMessages(ctx, "s1", &stores.GetMessagesOpts{Limit: 2})
	if err != nil {
		t.Fatalf("GetMessages with limit: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(got))
	}

	// Test with offset.
	got, err = store.GetMessages(ctx, "s1", &stores.GetMessagesOpts{Limit: 10, Offset: 1})
	if err != nil {
		t.Fatalf("GetMessages with offset: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 messages with offset, got %d", len(got))
	}
	if got[0].Content != "Hi there!" {
		t.Errorf("expected 'Hi there!', got %q", got[0].Content)
	}
}

func TestContextStore_AppendBatch(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)

	msgs := []stores.Message{
		{Role: "user", Content: "msg1"},
		{Role: "assistant", Content: "msg2"},
		{Role: "user", Content: "msg3"},
	}

	if err := store.AppendBatch(ctx, "s1", msgs, 2); err != nil {
		t.Fatalf("AppendBatch: %v", err)
	}

	count, err := store.GetMessageCount(ctx, "s1")
	if err != nil {
		t.Fatalf("GetMessageCount: %v", err)
	}
	if count != 3 {
		t.Fatalf("expected 3 messages, got %d", count)
	}
}

func TestContextStore_GetMessageCount(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)

	count, err := store.GetMessageCount(ctx, "s1")
	if err != nil {
		t.Fatalf("GetMessageCount: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected 0, got %d", count)
	}

	store.Append(ctx, "s1", stores.Message{Role: "user", Content: "hello"})

	count, err = store.GetMessageCount(ctx, "s1")
	if err != nil {
		t.Fatalf("GetMessageCount: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1, got %d", count)
	}
}

func TestContextStore_GetWindow(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)

	for i := 0; i < 10; i++ {
		store.Append(ctx, "s1", stores.Message{Role: "user", Content: "This is a test message with some content that takes tokens."})
	}

	win, err := store.GetWindow(ctx, "s1", 100)
	if err != nil {
		t.Fatalf("GetWindow: %v", err)
	}

	if win.TotalMessages != 10 {
		t.Errorf("expected 10 total messages, got %d", win.TotalMessages)
	}
	if win.WindowedMessages == 0 {
		t.Error("expected at least one windowed message")
	}
	if win.WindowedMessages > win.TotalMessages {
		t.Error("windowed messages should not exceed total")
	}
}

func TestContextStore_Search(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)
	store.Append(ctx, "s1", stores.Message{Role: "user", Content: "Tell me about Go programming"})
	store.Append(ctx, "s1", stores.Message{Role: "assistant", Content: "Go is a compiled language"})
	store.Append(ctx, "s1", stores.Message{Role: "user", Content: "What about Python?"})

	results, err := store.Search(ctx, "s1", "Go", 10)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}
}

func TestContextStore_SummarizeAndGetSummary(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)
	store.Append(ctx, "s1", stores.Message{Role: "user", Content: "Hello"})
	store.Append(ctx, "s1", stores.Message{Role: "assistant", Content: "Hi!"})

	// No summary initially.
	summary, err := store.GetSummary(ctx, "s1")
	if err != nil {
		t.Fatalf("GetSummary: %v", err)
	}
	if summary != nil {
		t.Error("expected nil summary initially")
	}

	// Create summary.
	result, err := store.Summarize(ctx, "s1", 2)
	if err != nil {
		t.Fatalf("Summarize: %v", err)
	}
	if result == "" {
		t.Error("expected non-empty summary")
	}

	// Retrieve summary.
	summary, err = store.GetSummary(ctx, "s1")
	if err != nil {
		t.Fatalf("GetSummary after summarize: %v", err)
	}
	if summary == nil {
		t.Fatal("expected non-nil summary")
	}
	if *summary == "" {
		t.Error("expected non-empty summary string")
	}
}

func TestContextStore_ToolCalls(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)

	msg := stores.Message{
		Role:    "assistant",
		Content: "Let me search for that.",
		ToolCalls: []stores.ToolCall{
			{Name: "search", Arguments: map[string]interface{}{"query": "Go sqlite"}},
		},
	}

	if err := store.Append(ctx, "s1", msg); err != nil {
		t.Fatalf("Append: %v", err)
	}

	got, err := store.GetMessages(ctx, "s1", nil)
	if err != nil {
		t.Fatalf("GetMessages: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 message, got %d", len(got))
	}
	if len(got[0].ToolCalls) != 1 {
		t.Fatalf("expected 1 tool call, got %d", len(got[0].ToolCalls))
	}
	if got[0].ToolCalls[0].Name != "search" {
		t.Errorf("expected tool call name 'search', got %q", got[0].ToolCalls[0].Name)
	}
}

func TestContextStore_CascadeDeleteMessages(t *testing.T) {
	store := newTestContextStore(t)
	ctx := context.Background()

	store.CreateSession(ctx, "s1", nil)
	store.Append(ctx, "s1", stores.Message{Role: "user", Content: "Hello"})
	store.Summarize(ctx, "s1", 1)
	store.DestroySession(ctx, "s1")

	// Messages should be gone.
	count, err := store.GetMessageCount(ctx, "s1")
	if err != nil {
		t.Fatalf("GetMessageCount: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0 messages after cascade delete, got %d", count)
	}
}

// Verify ContextStore satisfies the interface at compile time.
var _ stores.ContextStore = (*ContextStore)(nil)
