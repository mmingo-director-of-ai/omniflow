package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestServePayloadReadyRequiresExecutionEvidence(t *testing.T) {
	// Keep the definition within the catalog limit while spanning several chunks.
	schema := map[string]interface{}{
		"type":                 "object",
		"description":          strings.Repeat("Schema metadata only. ", chunkBytes/8),
		"properties":           map[string]interface{}{},
		"additionalProperties": false,
	}
	definition := map[string]interface{}{
		"name": "read_fixture", "description": "Read fixture evidence", "inputSchema": schema,
	}
	digest := sha256.Sum256([]byte(jsonText(definition)))
	var executions atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var result interface{}
		switch request.Method {
		case "initialize":
			result = map[string]interface{}{
				"protocolVersion": "2025-11-25",
				"capabilities":    map[string]interface{}{"tools": map[string]interface{}{}},
				"serverInfo":      map[string]string{"name": "fixture", "version": "1"},
			}
		case "notifications/initialized":
			w.WriteHeader(http.StatusAccepted)
			return
		case "tools/list":
			result = map[string]interface{}{"tools": []interface{}{definition}}
		case "tools/call":
			executions.Add(1)
			result = map[string]interface{}{"content": []interface{}{
				map[string]string{"type": "text", "text": "The fixture label is persimmon."},
			}}
		default:
			t.Errorf("unexpected method %q", request.Method)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]interface{}{"jsonrpc": "2.0", "id": request.ID, "result": result}); err != nil {
			t.Error(err)
		}
	}))
	defer server.Close()

	c := newClient(t)
	c.write(t, frame{
		Type: "start", Prompt: "Read the fixture label.",
		Tools: []toolDefinition{
			{Name: "getMacContext", InputSchemaJSON: `{"type":"object"}`},
			{Name: "inspectLocalFiles", InputSchemaJSON: `{"type":"object"}`},
		},
		Servers: []mcpServerConfig{{
			ID: "fixture", Name: "Fixture", Transport: "http", URL: server.URL, Enabled: true,
			AllowedTools: []mcpApproval{{Name: "read_fixture", Digest: hex.EncodeToString(digest[:])}},
		}},
	})
	f := c.read(t)
	if f.Type != "model" || f.PayloadReady {
		t.Fatal("empty store was reported as execution evidence")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{
		Name: "mcp", ArgumentsJSON: `{"operation":"schema","server":"fixture","name":"read_fixture"}`,
	}}})
	if event := c.read(t); event.Type != "event" || !event.Success {
		t.Fatal("schema selection failed")
	}
	f = c.read(t)
	if f.Type != "model" || f.PayloadReady || f.MCPTool == nil || executions.Load() != 0 {
		t.Fatal("schema selection made execution evidence ready or executed the tool")
	}
	var receipt struct {
		ParameterDefinitionID string `json:"parameterDefinitionID"`
	}
	if len(f.Messages) == 0 || json.Unmarshal([]byte(f.Messages[len(f.Messages)-1].Content), &receipt) != nil || receipt.ParameterDefinitionID == "" || len(f.MCPTool.InputSchemaJSON) <= chunkBytes {
		t.Fatal("selection did not retain the parameter definition and its inspection reference")
	}

	// Explicitly reading schema text must still leave source analysis unavailable.
	c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{
		Name: "payload", ArgumentsJSON: jsonText(map[string]interface{}{"operation": "read", "id": receipt.ParameterDefinitionID, "offset": 1}),
	}}})
	if event := c.read(t); event.Type != "event" || !event.Success {
		t.Fatal("schema inspection failed")
	}
	f = c.read(t)
	if f.Type != "model" || f.PayloadReady || executions.Load() != 0 {
		t.Fatal("reading schema metadata made execution evidence ready")
	}
	var inspection struct {
		Payload payloadEntry `json:"payload"`
		Chunk   int          `json:"chunk"`
		Text    string       `json:"text"`
	}
	if len(f.Messages) == 0 || json.Unmarshal([]byte(f.Messages[len(f.Messages)-1].Content), &inspection) != nil || inspection.Payload.ID != receipt.ParameterDefinitionID || inspection.Payload.Kind != "schema" || inspection.Payload.Chunks < 2 || inspection.Chunk != 1 || inspection.Text == "" {
		t.Fatal("the compact selection receipt did not preserve explicit multi-chunk schema inspection")
	}

	c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{
		Name: "mcp", ArgumentsJSON: `{"operation":"call","server":"fixture","name":"read_fixture","argumentsJSON":"{}"}`,
	}}})
	if event := c.read(t); event.Type != "event" || !event.Success {
		t.Fatal("fixture execution failed")
	}
	f = c.read(t)
	if f.Type != "model" || !f.PayloadReady || executions.Load() != 1 {
		t.Fatal("actual execution evidence did not make the payload ready")
	}
	if len(f.Messages) == 0 || !strings.Contains(f.Messages[len(f.Messages)-1].Content, "persimmon") {
		t.Fatal("actual execution evidence did not reach the model")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, Content: "The label is persimmon."})
	if result := c.read(t); result.Type != "done" || result.StopReason != "stop" {
		t.Fatal("runtime did not finish after using execution evidence")
	}
	if err := <-c.done; err != nil {
		t.Fatal(err)
	}
}
