package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/mcp"
)

func TestMCPHTTPURLAndHeaderValidation(t *testing.T) {
	for _, endpoint := range []string{"http://example.com/mcp", "https://user:secret@example.com/mcp", "https://example.com/mcp#fragment", "https://example.com/\n", "file:///tmp/mcp", "https://"} {
		if _, _, err := validateMCPHTTP(mcpServerConfig{URL: endpoint}); err == nil {
			t.Fatalf("accepted invalid endpoint %q", endpoint)
		}
	}
	for _, endpoint := range []string{"https://example.com/mcp", "http://127.0.0.1:8000/mcp", "http://[::1]/mcp", "http://localhost/mcp"} {
		if _, _, err := validateMCPHTTP(mcpServerConfig{URL: endpoint}); err != nil {
			t.Fatal(err)
		}
	}
	for _, headers := range []map[string]string{{"Authorization": "Bearer fixture\r\nInjected: true"}, {"Host": "other.example"}, {"Mcp-Session-Id": "fixture"}, {"Accept": "*/*"}, {"Proxy-Authorization": "secret"}, {"Authorization": "", "authorization": "second"}} {
		if _, _, err := validateMCPHTTP(mcpServerConfig{URL: "https://example.com/mcp", Headers: headers}); err == nil {
			t.Fatal("accepted unsafe header")
		}
	}
}

func TestMCPHTTPSDKSessionPaginationAndToolApproval(t *testing.T) {
	var deleted, calls, notifications atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture" {
			t.Error("authorization not forwarded to selected endpoint")
		}
		if !strings.Contains(r.Header.Get("Accept"), "application/json") || !strings.Contains(r.Header.Get("Accept"), "text/event-stream") {
			t.Error("missing required Accept types")
		}
		if r.Method == http.MethodDelete {
			deleted.Add(1)
			w.WriteHeader(204)
			return
		}
		var request mcp.JSONRPCRequest
		if json.NewDecoder(r.Body).Decode(&request) != nil {
			t.Error("invalid JSON request")
			return
		}
		if request.Method != "initialize" {
			if r.Header.Get("Mcp-Session-Id") != "fixture-session" || r.Header.Get("Mcp-Protocol-Version") != "2025-11-25" {
				t.Error("session/protocol headers not retained")
			}
		}
		if request.Method == "notifications/initialized" {
			notifications.Add(1)
			w.WriteHeader(202)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		result := interface{}(nil)
		switch request.Method {
		case "initialize":
			w.Header().Set("Mcp-Session-Id", "fixture-session")
			result = map[string]interface{}{"protocolVersion": "2025-11-25", "capabilities": map[string]interface{}{"tools": map[string]interface{}{}}, "serverInfo": map[string]string{"name": "fixture", "version": "1"}}
		case "tools/list":
			var params map[string]interface{}
			_ = json.Unmarshal(request.Params, &params)
			name := "first"
			page := map[string]interface{}{}
			if params["cursor"] == "second-page" {
				name = "second"
			} else {
				page["nextCursor"] = "second-page"
			}
			page["tools"] = []interface{}{map[string]interface{}{"name": name, "description": "A fixture read", "inputSchema": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}, "additionalProperties": false}}}
			result = page
		case "tools/call":
			calls.Add(1)
			result = map[string]interface{}{"content": []interface{}{map[string]string{"type": "text", "text": "remote fixture evidence"}}}
		default:
			t.Errorf("unexpected method %s", request.Method)
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"jsonrpc": "2.0", "id": request.ID, "result": result})
	}))
	defer server.Close()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	store, err := newPayloadStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer store.close()
	host, err := newMCPHost([]mcpServerConfig{{ID: "remote", Name: "Fixture", Transport: "http", URL: server.URL, Headers: map[string]string{"Authorization": "Bearer fixture"}, Enabled: true}}, store)
	if err != nil {
		t.Fatal(err)
	}
	defer host.close()
	c, err := host.connect(context.Background(), "remote")
	if err != nil {
		t.Fatal(err)
	}
	if len(c.tools) != 2 || notifications.Load() != 1 {
		t.Fatal("SDK handshake or paginated discovery incomplete")
	}
	args := map[string]interface{}{"operation": "call", "server": "remote", "name": "first", "argumentsJSON": "{}"}
	if _, err = host.execute(context.Background(), args); err == nil || calls.Load() != 0 {
		t.Fatal("unapproved remote call reached server")
	}
	selectionArgs := map[string]interface{}{"operation": "schema", "server": "remote", "name": "first"}
	if _, err = host.execute(context.Background(), selectionArgs); err == nil || host.selectedTool() != nil {
		t.Fatal("unapproved schema selected a callable tool")
	}
	approveFixture(c, "first")
	selection, err := host.execute(context.Background(), selectionArgs)
	if err != nil || calls.Load() != 0 {
		t.Fatal("schema selection failed or executed the tool", err)
	}
	var receipt struct {
		Status                string `json:"status"`
		Server                string `json:"server"`
		Name                  string `json:"name"`
		Executed              *bool  `json:"executed"`
		ParameterDefinitionID string `json:"parameterDefinitionID"`
	}
	if json.Unmarshal([]byte(selection.(string)), &receipt) != nil || receipt.Status != "ready_to_call" || receipt.Server != "remote" || receipt.Name != "first" || receipt.Executed == nil || *receipt.Executed {
		t.Fatal("schema receipt lost explicit selection versus execution status")
	}
	storedSchema := store.entries[receipt.ParameterDefinitionID]
	if storedSchema == nil || storedSchema.Kind != "schema" || storedSchema.Source != "mcp:remote:first:schema" || storedSchema.Viewed != 0 || len(storedSchema.SHA256) != 64 {
		t.Fatal("schema receipt did not reference an unread stored parameter definition with provenance")
	}
	for _, omitted := range []string{"additionalProperties", `"payload"`, `"sha256"`, `"chunks"`, `"coverage"`, `"evidence"`} {
		if strings.Contains(selection.(string), omitted) {
			t.Fatal("schema content or storage bookkeeping leaked into selection receipt")
		}
	}
	selected := host.selectedTool()
	if selected == nil || selected.Server != "remote" || selected.Name != "first" || selected.InputSchemaJSON != jsonText(c.tools["first"].schema) {
		t.Fatal("native selected tool lost its actual parameter schema")
	}
	inspection, err := store.execute(context.Background(), map[string]interface{}{
		"operation": "read", "id": receipt.ParameterDefinitionID, "offset": 0.0,
	})
	if err != nil {
		t.Fatal("stored schema could not be explicitly inspected", err)
	}
	var inspected struct {
		Text         string       `json:"text"`
		CompleteText bool         `json:"completeText"`
		Coverage     string       `json:"coverage"`
		Payload      payloadEntry `json:"payload"`
	}
	if json.Unmarshal([]byte(inspection.(string)), &inspected) != nil || inspected.Text != selected.InputSchemaJSON || !inspected.CompleteText || inspected.Payload.Kind != "schema" || !strings.Contains(inspected.Coverage, "Schema metadata only") {
		t.Fatal("explicit schema inspection lost data or metadata classification")
	}
	result, err := host.execute(context.Background(), args)
	if err != nil || !strings.Contains(result.(string), "remote fixture evidence") || calls.Load() != 1 {
		t.Fatal("SDK approved remote call failed", err)
	}
	var execution struct {
		IsError  bool `json:"isError"`
		Evidence struct {
			Text         string       `json:"text"`
			CompleteText bool         `json:"completeText"`
			Payload      payloadEntry `json:"payload"`
		} `json:"evidence"`
	}
	if json.Unmarshal([]byte(result.(string)), &execution) != nil || execution.IsError || strings.TrimSpace(execution.Evidence.Text) != "remote fixture evidence" || !execution.Evidence.CompleteText || execution.Evidence.Payload.Kind != "text" || execution.Evidence.Payload.Source != "mcp:remote:first" || execution.Evidence.Payload.ID == receipt.ParameterDefinitionID {
		t.Fatal("schema selection contaminated the actual tool result or its provenance")
	}
	host.close()
	if deleted.Load() != 1 {
		t.Fatal("owned remote session was not terminated exactly once")
	}
}

func TestMCPHTTPSSERefusesHostRequestsAndRevokesCatalog(t *testing.T) {
	var rejected atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			ID     json.RawMessage   `json:"id"`
			Method string            `json:"method"`
			Error  *mcp.JSONRPCError `json:"error"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		if request.Error != nil {
			if request.Error.Code != -32601 {
				t.Error("sampling was not refused")
			}
			rejected.Add(1)
			w.WriteHeader(202)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, ": keepalive\n\nid: prime\ndata:\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"sample\",\"method\":\"sampling/createMessage\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n")
		_, _ = fmt.Fprintf(w, "data: {\"jsonrpc\":\"2.0\",\ndata: \"id\":%s,\"result\":{\"value\":9007199254740993}}\n\n", request.ID)
	}))
	defer server.Close()
	transport := &localMCPTransport{config: mcpServerConfig{Transport: "http", URL: server.URL}, ctx: context.Background()}
	if err := transport.Connect(); err != nil {
		t.Fatal(err)
	}
	defer transport.Close()
	raw, err := transport.rpc(context.Background(), "fixture/read", map[string]string{})
	if err != nil || !strings.Contains(string(raw), "9007199254740993") || !transport.catalogChanged || rejected.Load() != 1 {
		t.Fatal("SSE response, exact number, refusal or revocation failed", err)
	}
}

func TestMCPHTTPRejectsErrorsWithoutLeakingOrFollowingRedirects(t *testing.T) {
	var destinationCalls atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { destinationCalls.Add(1) }))
	defer destination.Close()
	cases := []struct {
		status int
		want   string
	}{{401, "mcp_authentication_required"}, {403, "mcp_http_forbidden"}, {404, "mcp_http_endpoint_unavailable"}, {429, "mcp_http_rate_limited"}, {307, "mcp_http_redirect_refused"}, {500, "mcp_http_status_error"}}
	for _, tc := range cases {
		t.Run(fmt.Sprint(tc.status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", destination.URL)
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, "SECRET_RESPONSE_BODY")
			}))
			defer server.Close()
			h, err := newMCPHTTP(mcpServerConfig{URL: server.URL, Headers: map[string]string{"Authorization": "Bearer fixture"}})
			if err != nil {
				t.Fatal(err)
			}
			defer h.close()
			err = h.post(context.Background(), map[string]string{"method": "initialize"}, true, true)
			if err == nil || err.Error() != tc.want || strings.Contains(err.Error(), "SECRET") {
				t.Fatal("unsafe/missing status error", err)
			}
		})
	}
	if destinationCalls.Load() != 0 {
		t.Fatal("followed redirect with credentials")
	}
}

func TestMCPHTTPBoundsFramesAndChecksIDs(t *testing.T) {
	cases := []struct {
		name, contentType, body string
		length                  int64
		want                    string
	}{
		{name: "wrong-id", contentType: "application/json", body: `{"jsonrpc":"2.0","id":"other","result":{}}`, want: "mcp_response_mismatch"},
		{name: "batch", contentType: "application/json", body: `[{"jsonrpc":"2.0","id":1,"result":{}}]`, want: "mcp_invalid_frame"},
		{name: "html", contentType: "text/html", body: "<html>auth</html>", want: "mcp_http_unsupported_content_type"},
		{name: "length", contentType: "application/json", length: maxMCPFrameBytes + 1, want: "mcp_http_response_limit"},
		{name: "stream-limit", contentType: "text/event-stream", body: "data: " + strings.Repeat("x", maxMCPFrameBytes) + "\n\n", want: "mcp_http_response_limit"},
		{name: "truncated-stream", contentType: "text/event-stream", body: "data: {}", want: "mcp_http_stream_ended_before_response"},
		{name: "notifications", contentType: "text/event-stream", body: strings.Repeat("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n", 65), want: "mcp_notification_limit"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.contentType)
				if tc.length != 0 {
					w.Header().Set("Content-Length", fmt.Sprint(tc.length))
				}
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			transport := &localMCPTransport{config: mcpServerConfig{Transport: "http", URL: server.URL}, ctx: context.Background()}
			if err := transport.Connect(); err != nil {
				t.Fatal(err)
			}
			defer transport.Close()
			_, err := transport.rpc(context.Background(), "fixture/read", map[string]string{})
			if err == nil || err.Error() != tc.want {
				t.Fatalf("wanted %s, got %v", tc.want, err)
			}
		})
	}
}

func TestMCPHTTPCancellationAndProtocolValidation(t *testing.T) {
	cancelled := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		cancelled <- struct{}{}
	}))
	defer server.Close()
	transport := &localMCPTransport{config: mcpServerConfig{Transport: "http", URL: server.URL}, ctx: context.Background()}
	if err := transport.Connect(); err != nil {
		t.Fatal(err)
	}
	defer transport.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := transport.rpc(ctx, "fixture/read", map[string]string{})
	if err == nil || err.Error() != "mcp_http_timeout" || time.Since(start) > time.Second {
		t.Fatal("HTTP cancellation did not finish promptly", err)
	}
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("HTTP cancellation did not reach server")
	}
	h := &mcpHTTPTransport{initializing: true}
	if h.finishResponse(json.RawMessage(`{"protocolVersion":"evil"}`), false) == nil {
		t.Fatal("accepted unsupported protocol")
	}
}

func TestMCPHTTPExpiredSessionReinitializesWithoutReplayingCall(t *testing.T) {
	var initialized, calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			w.WriteHeader(204)
			return
		}
		var request mcp.JSONRPCRequest
		_ = json.NewDecoder(r.Body).Decode(&request)
		if request.Method == "notifications/initialized" {
			w.WriteHeader(202)
			return
		}
		if request.Method != "initialize" {
			calls.Add(1)
			w.WriteHeader(404)
			return
		}
		n := initialized.Add(1)
		if r.Header.Get("Mcp-Session-Id") != "" {
			t.Error("new initialize reused expired session")
		}
		w.Header().Set("Mcp-Session-Id", fmt.Sprintf("session-%d", n))
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"jsonrpc": "2.0", "id": request.ID, "result": map[string]interface{}{"protocolVersion": "2025-11-25", "capabilities": map[string]interface{}{}, "serverInfo": map[string]string{"name": "fixture", "version": "1"}}})
	}))
	defer server.Close()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	store, err := newPayloadStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer store.close()
	host, err := newMCPHost([]mcpServerConfig{{ID: "remote", Transport: "http", URL: server.URL, Enabled: true}}, store)
	if err != nil {
		t.Fatal(err)
	}
	defer host.close()
	c, err := host.connect(context.Background(), "remote")
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.transport.rpc(context.Background(), "tools/call", map[string]string{"name": "fixture"})
	if err == nil || err.Error() != "mcp_http_endpoint_unavailable" {
		t.Fatal("expired session was not reported", err)
	}
	next, err := host.connect(context.Background(), "remote")
	if err != nil || next == c || initialized.Load() != 2 || calls.Load() != 1 {
		t.Fatal("session was not renewed cleanly, or failed call was replayed", err)
	}
}
