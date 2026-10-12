package mcp

import (
	"context"
	"testing"
)

func TestManagerEmptyAndMissingServerPaths(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	ctx := context.Background()
	if len(manager.ListServers()) != 0 || len(manager.AllTools()) != 0 {
		t.Fatal("new manager should be empty")
	}
	if _, err := manager.GetTools("missing"); err == nil {
		t.Fatal("missing tools should fail")
	}
	if _, err := manager.CallTool(ctx, "missing", "tool", nil); err == nil {
		t.Fatal("missing call should fail")
	}
	if err := manager.Disconnect(ctx, "missing"); err == nil {
		t.Fatal("missing disconnect should fail")
	}
	if err := manager.DisconnectAll(ctx); err != nil {
		t.Fatal(err)
	}

	if (TextContent{}).ContentType() != "text" || (ImageContent{}).ContentType() != "image" || (ResourceContent{}).ContentType() != "resource" {
		t.Fatal("content block type mismatch")
	}
}

func TestManagerRejectsUnsupportedTransportAndReleasesName(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	ctx := context.Background()
	for range 2 {
		if _, err := manager.Connect(ctx, "bad", TransportConfig{Type: "unsupported"}); err == nil {
			t.Fatal("unsupported transport should fail")
		}
	}
}
