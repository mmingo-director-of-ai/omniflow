package conversation

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/intelligence"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
	storesqlite "gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores/sqlite"
)

type barrierMemoryStore struct {
	stores.MemoryStore
	atomic   stores.AtomicMemoryStore
	mu       sync.Mutex
	arrivals int
	gate     chan struct{}
}

func newBarrierMemoryStore(store stores.MemoryStore) *barrierMemoryStore {
	return &barrierMemoryStore{
		MemoryStore: store,
		atomic:      store.(stores.AtomicMemoryStore),
		gate:        make(chan struct{}),
	}
}

func (s *barrierMemoryStore) CompareAndSwap(ctx context.Context, id string, expectedUpdatedAt int64, entry stores.StoredMemoryEntry) (bool, error) {
	s.mu.Lock()
	s.arrivals++
	if s.arrivals == 2 {
		close(s.gate)
	}
	s.mu.Unlock()
	<-s.gate
	return s.atomic.CompareAndSwap(ctx, id, expectedUpdatedAt, entry)
}

func TestCheckpointForkRestartAndValidation(t *testing.T) {
	ctx := context.Background()
	contextStoreRaw, _ := storesqlite.NewContextStore(stores.StoreConfig{URL: ":memory:"})
	memoryStoreRaw, _ := storesqlite.NewMemoryStore(stores.StoreConfig{URL: ":memory:"})
	_ = contextStoreRaw.Init(ctx)
	_ = memoryStoreRaw.Init(ctx)
	t.Cleanup(func() { _ = contextStoreRaw.Close(ctx); _ = memoryStoreRaw.Close(ctx) })
	_ = contextStoreRaw.CreateSession(ctx, "root", &stores.SessionMetadata{CreatedAt: 1})
	_ = contextStoreRaw.AppendBatch(ctx, "root", []stores.Message{{Role: "user", Content: "hello"}, {Role: "assistant", Content: "hi"}}, 100)
	scope := intelligence.Scope{TenantID: "tenant-a", SubjectID: "user-a"}
	manager := New(contextStoreRaw, memoryStoreRaw, Options{Clock: func() time.Time { return time.UnixMilli(100) }})
	root, err := manager.Checkpoint(ctx, scope, "root", CheckpointOptions{})
	if err != nil {
		t.Fatal(err)
	}
	fork, err := manager.Fork(ctx, scope, root.ID, "feature", "feature-session")
	if err != nil || fork.ParentCheckpointID != root.ID {
		t.Fatalf("fork failed: %#v %v", fork, err)
	}
	if err := contextStoreRaw.Append(ctx, "feature-session", stores.Message{Role: "user", Content: "feature work"}); err != nil {
		t.Fatal(err)
	}
	featureHead, err := manager.Checkpoint(ctx, scope, "feature-session", CheckpointOptions{BranchID: "feature", ExpectedHeadCheckpointID: fork.ID})
	if err != nil {
		t.Fatal(err)
	}
	manual, err := manager.MergeWithResolver(ctx, scope, featureHead.ID, "root", "manual", func(source Checkpoint, target Checkpoint) ([]stores.Message, error) {
		messages := cloneMessages(target.Messages)
		return append(messages, stores.Message{Role: "user", Content: "manual resolution"}), nil
	})
	if err != nil || manual.Metadata["strategy"] != "manual" {
		t.Fatalf("manual merge failed: %#v %v", manual, err)
	}
	restarted := New(contextStoreRaw, memoryStoreRaw, Options{})
	messages, _, err := restarted.Resume(ctx, scope, root.ID, "restored", false)
	if err != nil || len(messages) != 2 {
		t.Fatalf("resume failed: %#v %v", messages, err)
	}
	bundle, err := manager.Export(ctx, scope, root.ID)
	if err != nil {
		t.Fatal(err)
	}
	targetRaw, _ := storesqlite.NewMemoryStore(stores.StoreConfig{URL: ":memory:"})
	_ = targetRaw.Init(ctx)
	defer targetRaw.Close(ctx)
	if _, err := New(contextStoreRaw, targetRaw, Options{}).Import(ctx, scope, bundle); err != nil {
		t.Fatal(err)
	}
	if err := ValidateHistory([]stores.Message{{Role: "tool", Content: "bad", ToolCallID: "missing"}}); err == nil {
		t.Fatal("expected malformed tool history error")
	}
	denied := New(contextStoreRaw, memoryStoreRaw, Options{Authorize: func(_ context.Context, request AuthorizationRequest) (bool, error) {
		return request.Action != "export", nil
	}})
	if _, err := denied.Export(ctx, scope, root.ID); err == nil {
		t.Fatal("expected export authorization failure")
	}
}

func TestConcurrentBranchWritersHaveOneWinner(t *testing.T) {
	ctx := context.Background()
	contextStore, _ := storesqlite.NewContextStore(stores.StoreConfig{URL: ":memory:"})
	memoryStore, _ := storesqlite.NewMemoryStore(stores.StoreConfig{URL: ":memory:"})
	if err := contextStore.Init(ctx); err != nil {
		t.Fatal(err)
	}
	if err := memoryStore.Init(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = contextStore.Close(ctx); _ = memoryStore.Close(ctx) })
	if err := contextStore.CreateSession(ctx, "root", &stores.SessionMetadata{CreatedAt: 1}); err != nil {
		t.Fatal(err)
	}
	if err := contextStore.AppendBatch(ctx, "root", []stores.Message{{Role: "user", Content: "hello"}}, 100); err != nil {
		t.Fatal(err)
	}

	barrier := newBarrierMemoryStore(memoryStore)
	scope := intelligence.Scope{TenantID: "tenant-a", SubjectID: "user-a"}
	manager := New(contextStore, barrier, Options{Clock: func() time.Time { return time.UnixMilli(100) }})
	first, err := manager.Checkpoint(ctx, scope, "root", CheckpointOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := contextStore.Append(ctx, "root", stores.Message{Role: "user", Content: "concurrent"}); err != nil {
		t.Fatal(err)
	}

	type outcome struct {
		checkpoint Checkpoint
		err        error
	}
	outcomes := make(chan outcome, 2)
	for range 2 {
		go func() {
			checkpoint, checkpointErr := manager.Checkpoint(ctx, scope, "root", CheckpointOptions{ExpectedHeadCheckpointID: first.ID})
			outcomes <- outcome{checkpoint: checkpoint, err: checkpointErr}
		}()
	}

	winners := 0
	conflicts := 0
	for range 2 {
		result := <-outcomes
		if result.err == nil {
			winners++
			continue
		}
		var conflict *ConflictError
		if errors.As(result.err, &conflict) {
			conflicts++
			continue
		}
		t.Fatalf("unexpected checkpoint error: %v", result.err)
	}
	if winners != 1 || conflicts != 1 {
		t.Fatalf("expected one winner and one conflict, got winners=%d conflicts=%d", winners, conflicts)
	}
	branch, err := manager.GetBranch(ctx, scope, "root")
	if err != nil || branch == nil || branch.Revision != 2 {
		t.Fatalf("unexpected branch after race: %#v %v", branch, err)
	}
	entries, err := memoryStore.LoadAll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	checkpoints := 0
	for _, entry := range entries {
		if entry.Source == checkpointSource {
			checkpoints++
		}
	}
	if checkpoints != 2 {
		t.Fatalf("expected root plus winning checkpoint, got %d", checkpoints)
	}
}
