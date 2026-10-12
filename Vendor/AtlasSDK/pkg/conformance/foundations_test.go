package conformance

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/conversation"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/intelligence"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
	storesqlite "gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores/sqlite"
)

func TestPortableFoundationBundles(t *testing.T) {
	data, err := os.ReadFile("../../../../fixtures/platform-foundations.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Portability struct {
			Intelligence intelligence.Bundle `json:"intelligence"`
			Conversation conversation.Export `json:"conversation"`
		} `json:"portability"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	records, err := storesqlite.NewMemoryStore(stores.StoreConfig{URL: ":memory:"})
	if err != nil {
		t.Fatal(err)
	}
	if err := records.Init(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = records.Close(ctx) })

	scope := fixture.Portability.Intelligence.Scope
	imported, skipped, err := intelligence.New(records, intelligence.Options{}).Import(
		ctx,
		scope,
		fixture.Portability.Intelligence,
		"error",
	)
	if err != nil || imported != 1 || skipped != 0 {
		t.Fatalf("canonical intelligence import failed: imported=%d skipped=%d err=%v", imported, skipped, err)
	}

	checkpoint, err := conversation.New(nil, records, conversation.Options{}).Import(
		ctx,
		fixture.Portability.Conversation.Scope,
		fixture.Portability.Conversation,
	)
	if err != nil {
		t.Fatal(err)
	}
	if checkpoint.ID != "checkpoint-1" || checkpoint.HistoryHash != fixture.Portability.Conversation.Checkpoint.HistoryHash {
		t.Fatalf("unexpected imported checkpoint: %#v", checkpoint)
	}
}
