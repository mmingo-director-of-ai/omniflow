package intelligence

import (
	"context"
	"testing"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
	storesqlite "gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores/sqlite"
)

func testIntelligence(t *testing.T, now *time.Time) (*PersistentIntelligence, stores.MemoryStore) {
	t.Helper()
	store, err := storesqlite.NewMemoryStore(stores.StoreConfig{URL: ":memory:"})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close(context.Background()) })
	service := New(store, Options{
		Clock: func() time.Time { return *now },
		Embed: func(_ context.Context, text string) ([]float64, error) {
			if text == "semantic memory" || text == "semantic query" {
				return []float64{1, 0}, nil
			}
			return []float64{0, 1}, nil
		},
	})
	return service, store
}

func TestPersistentIntelligenceScopeRetentionAndPortability(t *testing.T) {
	ctx := context.Background()
	now := time.UnixMilli(1000)
	service, store := testIntelligence(t, &now)
	scope := Scope{TenantID: "tenant-a", SubjectID: "user-a"}
	id, err := service.Save(ctx, scope, SaveInput{Content: "semantic memory", Source: "test", Privacy: "private", TTL: time.Millisecond * 5})
	if err != nil {
		t.Fatal(err)
	}
	record, err := store.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if record.Metadata["tenantId"] != "tenant-a" || len(record.Embedding) != 2 {
		t.Fatalf("metadata/embedding did not round-trip: %#v", record)
	}

	results, err := service.Retrieve(ctx, Query{Text: "semantic query", Scope: scope, Threshold: .9})
	if err != nil || len(results) != 1 {
		t.Fatalf("semantic retrieval failed: %v %#v", err, results)
	}
	other, err := service.Retrieve(ctx, Query{Text: "", Scope: Scope{TenantID: "tenant-a", SubjectID: "user-b"}})
	if err != nil || len(other) != 0 {
		t.Fatalf("private scope leaked: %#v", other)
	}

	bundle, err := service.Export(ctx, scope)
	if err != nil {
		t.Fatal(err)
	}
	now = time.UnixMilli(2000)
	purged, err := service.PurgeExpired(ctx, scope)
	if err != nil || purged != 1 {
		t.Fatalf("expected one expired record, got %d: %v", purged, err)
	}

	target, _ := testIntelligence(t, &now)
	imported, skipped, err := target.Import(ctx, scope, bundle, "error")
	if err != nil || imported != 1 || skipped != 0 {
		t.Fatalf("import failed: %d %d %v", imported, skipped, err)
	}
}
