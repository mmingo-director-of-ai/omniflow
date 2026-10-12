package mcp

import (
	"encoding/json"
	"testing"
)

func TestToolResultDecodesConcreteContentBlocks(t *testing.T) {
	var result ToolResult
	if err := json.Unmarshal([]byte(`{"content":[{"type":"text","text":"ok"},{"type":"image","data":"AA==","mimeType":"image/png"},{"type":"audio","data":"AA==","mimeType":"audio/wav"},{"type":"resource_link","uri":"file:///report","name":"report"},{"type":"resource","resource":{"uri":"file:///embedded","mimeType":"text/plain","text":"body"}}],"structuredContent":{"ok":true}}`), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Content) != 5 || result.StructuredContent["ok"] != true {
		t.Fatalf("unexpected content: %#v", result.Content)
	}
	if text, ok := result.Content[0].(*TextContent); !ok || text.Text != "ok" {
		t.Fatalf("text block lost its concrete type: %#v", result.Content[0])
	}
	if _, ok := result.Content[1].(*ImageContent); !ok {
		t.Fatalf("image block lost its concrete type: %#v", result.Content[1])
	}
	if _, ok := result.Content[2].(*AudioContent); !ok {
		t.Fatalf("audio block lost its concrete type: %#v", result.Content[2])
	}
	if _, ok := result.Content[3].(*ResourceLinkContent); !ok {
		t.Fatalf("resource link lost its concrete type: %#v", result.Content[3])
	}
	if embedded, ok := result.Content[4].(*ResourceContent); !ok || embedded.URI != "file:///embedded" || embedded.Text != "body" {
		t.Fatalf("embedded resource lost its concrete type: %#v", result.Content[4])
	}
	if err := json.Unmarshal([]byte(`{"content":[{"type":"unknown"}]}`), &result); err == nil {
		t.Fatal("unsupported content types must fail explicitly")
	}
}
