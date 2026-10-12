package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

func TestServeInitialMCPDiscoveryIsBoundedApprovedMetadata(t *testing.T) {
	var definitions []interface{}
	var approvals []mcpApproval
	for i := 1; i <= 12; i++ {
		name := fmt.Sprintf("read_%02d", i)
		schema := map[string]interface{}{"type": "object", "properties": map[string]interface{}{}, "additionalProperties": false}
		if i == 12 {
			schema["format"] = "unsupported"
		}
		definition := map[string]interface{}{"name": name, "description": strings.Repeat("café 紅熊猫. ", 30), "inputSchema": schema}
		definitions = append(definitions, definition)
		if i == 10 { // advertised but never approved
			continue
		}
		digest := sha256.Sum256([]byte(jsonText(definition)))
		approval := mcpApproval{Name: name, Digest: hex.EncodeToString(digest[:])}
		if i == 11 { // a stale approval must not become a current capability
			approval.Digest = strings.Repeat("0", 64)
		}
		approvals = append(approvals, approval)
	}
	var initialized, listed, called, denied atomic.Int32
	const credential = "Bearer discovery-fixture-private-token"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/denied" {
			denied.Add(1)
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte("PRIVATE_REMOTE_ERROR_BODY"))
			return
		}
		if r.Header.Get("Authorization") != credential {
			t.Error("fixture credential missing from its transport")
		}
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
			return
		}
		var result interface{}
		switch request.Method {
		case "initialize":
			initialized.Add(1)
			result = map[string]interface{}{"protocolVersion": "2025-11-25", "capabilities": map[string]interface{}{"tools": map[string]interface{}{}}, "serverInfo": map[string]string{"name": "fixture", "version": "1"}}
		case "notifications/initialized":
			w.WriteHeader(http.StatusAccepted)
			return
		case "tools/list":
			listed.Add(1)
			result = map[string]interface{}{"tools": definitions}
		case "tools/call":
			called.Add(1)
			t.Error("metadata discovery executed a remote operation")
			result = map[string]interface{}{"content": []interface{}{}}
		default:
			t.Errorf("unexpected method %q", request.Method)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"jsonrpc": "2.0", "id": request.ID, "result": result})
	}))
	defer server.Close()

	c := newClient(t)
	c.write(t, frame{Type: "start", Prompt: "Read a project note, or use native context if a connection fails.",
		Tools: []toolDefinition{{Name: "getMacContext", InputSchemaJSON: `{"type":"object"}`}, {Name: "inspectLocalFiles", InputSchemaJSON: `{"type":"object"}`}},
		Servers: []mcpServerConfig{
			{ID: "denied", Name: "Unavailable connection", Transport: "http", URL: server.URL + "/denied", Enabled: true},
			{ID: "enabled", Name: "Available connection", Transport: "http", URL: server.URL, Headers: map[string]string{"Authorization": credential}, Enabled: true, AllowedTools: approvals},
			{ID: "disabled", Name: "Disabled connection", Transport: "http", URL: server.URL + "/denied"},
		}})
	f := c.read(t)
	if f.Type != "model" || f.Step != 1 || f.PayloadReady || f.MCPTool != nil || called.Load() != 0 {
		t.Fatal("bootstrap selected/executed a tool or changed the normal first model step")
	}
	if len(f.MCPDiscovery) != 2 || f.MCPDiscovery[0].Error != "mcp_authentication_required" || f.MCPDiscovery[1].Error != "" {
		t.Fatal("one failed connection blocked independent metadata discovery")
	}
	discovered := f.MCPDiscovery[1]
	if discovered.Server != "enabled" || discovered.Name != "Available connection" || discovered.ToolCount != 9 || !discovered.HasMore || len(discovered.Tools) != 8 {
		t.Fatal("discovery failed to filter live approvals or bound the first page")
	}
	for index, tool := range discovered.Tools {
		if tool.Name != fmt.Sprintf("read_%02d", index+1) || len(tool.Description) > 200 || !utf8.ValidString(tool.Description) {
			t.Fatal("metadata was not sorted or its description exceeded the UTF-8 byte limit")
		}
	}
	encoded := jsonText(f)
	for _, private := range []string{credential, "PRIVATE_REMOTE_ERROR_BODY", `"headers"`, `"inputSchemaJSON"`} {
		if strings.Contains(encoded, private) {
			t.Fatal("transport credentials, raw failure or full schema leaked into discovery")
		}
	}

	// A failed remote server does not block a normal native tool/answer path.
	c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{Name: "getMacContext", ArgumentsJSON: `{}`}}})
	f = c.read(t)
	if f.Type != "tool" || f.Tool != "getMacContext" {
		t.Fatal("native tools were unavailable after discovery failure")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, Content: "Native fixture evidence."})
	_ = c.read(t) // native execution event
	f = c.read(t)
	if f.Type != "model" || len(f.MCPDiscovery) != 2 || initialized.Load() != 1 || listed.Load() != 1 || denied.Load() != 1 {
		t.Fatal("a later model step repeated automatic metadata probes")
	}

	// Catalog filtering is metadata search, not a search of remote documents.
	c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{Name: "mcp", ArgumentsJSON: `{"operation":"tools","server":"enabled","query":"a document title not in tool metadata"}`}}})
	_ = c.read(t)
	f = c.read(t)
	var filtered struct {
		Total       int                `json:"total"`
		ToolCount   int                `json:"toolCount"`
		SearchScope string             `json:"searchScope"`
		Filter      string             `json:"filter"`
		Tools       []mcpDiscoveryTool `json:"tools"`
	}
	if f.Type != "model" || len(f.Messages) == 0 || json.Unmarshal([]byte(f.Messages[len(f.Messages)-1].Content), &filtered) != nil || filtered.Total != 0 || filtered.ToolCount != 9 || filtered.SearchScope != "tool_catalog" || filtered.Filter == "" || len(filtered.Tools) != 0 {
		t.Fatal("empty catalog filter concealed other approved capabilities")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{Name: "mcp", ArgumentsJSON: `{"operation":"tools","server":"enabled","offset":8}`}}})
	_ = c.read(t)
	f = c.read(t)
	if len(f.Messages) == 0 || json.Unmarshal([]byte(f.Messages[len(f.Messages)-1].Content), &filtered) != nil || filtered.Total != 9 || len(filtered.Tools) != 1 || filtered.Tools[0].Name != "read_09" || listed.Load() != 1 || called.Load() != 0 {
		t.Fatal("explicit pagination stopped working or repeated the network catalog query")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, Content: "Native fixture evidence is available."})
	if result := c.read(t); result.Type != "done" || result.StopReason != "stop" {
		t.Fatal("metadata failure prevented the run from answering")
	}
	if err := <-c.done; err != nil {
		t.Fatal(err)
	}
}

func TestMCPDiscoveryCancellationAndSafeErrors(t *testing.T) {
	var requests atomic.Int32
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer func() { close(release); server.Close() }()
	store := coverageStore(t)
	host, err := newMCPHost([]mcpServerConfig{{ID: "slow", Name: "Slow fixture", Transport: "http", URL: server.URL, Enabled: true}}, store)
	if err != nil {
		t.Fatal(err)
	}
	defer host.close()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	started := time.Now()
	metadata := host.discover(ctx, "")
	if len(metadata) != 1 || !strings.HasSuffix(metadata[0].Error, "timeout") || time.Since(started) > time.Second || requests.Load() != 1 {
		t.Fatal("metadata discovery did not respect its caller deadline")
	}
	ctx, cancel = context.WithCancel(context.Background())
	cancel()
	metadata = host.discover(ctx, "")
	if len(metadata) != 1 || metadata[0].Error != "mcp_discovery_cancelled" || requests.Load() != 1 {
		t.Fatal("cancelled discovery initiated another connection")
	}
	if discoveryError(errors.New("private_token_from_remote_service")) != "mcp_discovery_failed" {
		t.Fatal("arbitrary remote error text was exposed as capability metadata")
	}
}

func discoveryRankingConnection() *mcpConnection {
	connection := &mcpConnection{transport: &localMCPTransport{}, tools: map[string]mcpCatalogTool{}}
	add := func(name, description string, approved, supported bool) {
		tool := mcpCatalogTool{Name: name, Description: description, Digest: strings.Repeat("a", 64), Supported: supported}
		connection.tools[name] = tool
		if approved {
			connection.config.AllowedTools = append(connection.config.AllowedTools, mcpApproval{Name: name, Digest: tool.Digest})
		}
	}
	for i := 1; i <= 9; i++ {
		add(fmt.Sprintf("read_%02d", i), "Read local service metadata", true, true)
	}
	add("zeta_relationships", "Search CRM contacts, customers and deals", true, true)
	add("private_unapproved", "CRM contacts customers deals", false, true)
	add("private_unsupported", "CRM contacts customers deals", true, false)
	add("private_stale", "CRM contacts customers deals", true, true)
	connection.tools["private_stale"] = mcpCatalogTool{Name: "private_stale", Description: "CRM contacts", Digest: strings.Repeat("b", 64), Supported: true}
	return connection
}

func TestMCPDiscoveryRanksOnlyCurrentApprovalsBeforeEightToolLimit(t *testing.T) {
	connection := discoveryRankingConnection()
	connection.config.ID, connection.config.Name, connection.config.Enabled = "fixture", "Available fixture", true
	connection.config.Headers = map[string]string{"Authorization": "PRIVATE_TRANSPORT_CREDENTIAL"}
	host := &mcpHost{configs: []mcpServerConfig{connection.config}, connections: map[string]*mcpConnection{"fixture": connection}}
	metadata := host.discover(context.Background(), "Show my CRM contacts. PRIVATE_QUERY_MARKER")
	if len(metadata) != 1 || metadata[0].ToolCount != 10 || !metadata[0].HasMore || len(metadata[0].Tools) != 8 || metadata[0].Tools[0].Name != "zeta_relationships" {
		t.Fatal("relevant approved capability beyond the alphabetical first page was omitted")
	}
	for _, tool := range metadata[0].Tools {
		if strings.HasPrefix(tool.Name, "private_") {
			t.Fatal("a matching unsupported, unapproved, or stale tool entered discovery")
		}
	}
	for _, private := range []string{"PRIVATE_TRANSPORT_CREDENTIAL", "PRIVATE_QUERY_MARKER", "Authorization", "headers"} {
		if strings.Contains(jsonText(metadata), private) {
			t.Fatal("ranking exposed private configuration or query data")
		}
	}
	baseline := rankedDiscoveryNames(connection, "CRM contacts")
	for range 20 {
		if got := rankedDiscoveryNames(connection, strings.Repeat("CRM contacts ", 20)); !reflect.DeepEqual(got, baseline) {
			t.Fatal("duplicate query words or map iteration changed deterministic ranking")
		}
	}
	exact := rankedDiscoveryNames(connection, "Use `read_09` for the CRM contacts")
	if exact[0] != "read_09" {
		t.Fatal("exact approved tool identifier did not outrank a description-only match")
	}
	for _, query := range []string{"", "please show me what the tools can do", strings.Repeat(" ", 8000) + "CRM contacts"} {
		if got := rankedDiscoveryNames(connection, query); len(got) != 10 || got[0] != "read_01" || got[9] != "zeta_relationships" {
			t.Fatal("empty, stop-word-only, or out-of-bound query changed stable default ordering")
		}
	}
	connection.transport.catalogChanged = true
	if got := rankedDiscoveryNames(connection, "zeta_relationships CRM contacts"); len(got) != 0 {
		t.Fatal("ranking restored grants revoked by catalog change")
	}
}

func TestMCPDiscoveryNameBoundariesAndUnicodeTerms(t *testing.T) {
	for _, query := range []string{"read_090", "prefix-read_09", "read_09.extra", "read_09_suffix"} {
		if discoveryExactName(query, "read_09") {
			t.Fatal("a partial identifier became an exact tool-name match")
		}
	}
	if !discoveryExactName("Use `READ_09` now", "READ_09") || !discoveryTerms("紅熊猫 café CRM CRM", 32)["紅熊猫"] {
		t.Fatal("quoted exact names or meaningful Unicode terms were lost")
	}
	if len(discoveryTerms(strings.Repeat("CRM ", 200), 32)) != 1 {
		t.Fatal("repeated metadata/query terms accumulated weight")
	}
}

func TestServeDiscoveryQueryOverridesQuestionAndRemainsHostOnly(t *testing.T) {
	var definitions []interface{}
	var approvals []mcpApproval
	for name, tool := range discoveryRankingConnection().tools {
		if strings.HasPrefix(name, "private_") {
			continue
		}
		definition := map[string]interface{}{"name": name, "description": tool.Description,
			"inputSchema": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}, "additionalProperties": false}}
		definitions = append(definitions, definition)
		digest := sha256.Sum256([]byte(jsonText(definition)))
		approvals = append(approvals, mcpApproval{Name: name, Digest: hex.EncodeToString(digest[:])})
	}
	var probes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			w.WriteHeader(204)
			return
		}
		data, _ := io.ReadAll(r.Body)
		if strings.Contains(string(data), "PRIVATE_QUERY_MARKER") {
			t.Error("host ranking sent the user query to the MCP server")
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		_ = json.Unmarshal(data, &request)
		var result interface{}
		switch request.Method {
		case "initialize":
			probes.Add(1)
			result = map[string]interface{}{"protocolVersion": "2025-11-25", "capabilities": map[string]interface{}{"tools": map[string]interface{}{}}, "serverInfo": map[string]string{"name": "fixture", "version": "1"}}
		case "notifications/initialized":
			w.WriteHeader(202)
			return
		case "tools/list":
			result = map[string]interface{}{"tools": definitions}
		default:
			t.Errorf("query ranking attempted a non-discovery operation: %s", request.Method)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"jsonrpc": "2.0", "id": request.ID, "result": result})
	}))
	defer server.Close()
	for _, tc := range []struct{ query, question, first string }{
		{"CRM contacts PRIVATE_QUERY_MARKER", "unrelated", "zeta_relationships"},
		{"", "CRM contacts", "zeta_relationships"},
		{"unrelated", "CRM contacts", "read_01"},
	} {
		c := newClient(t)
		c.write(t, frame{Type: "start", Prompt: "Rank only approved capability metadata.", DiscoveryQuery: tc.query, Question: tc.question,
			Tools:   []toolDefinition{{Name: "getMacContext", InputSchemaJSON: `{"type":"object"}`}, {Name: "inspectLocalFiles", InputSchemaJSON: `{"type":"object"}`}},
			Servers: []mcpServerConfig{{ID: "fixture", Name: "Fixture", Enabled: true, Transport: "http", URL: server.URL, AllowedTools: approvals}}})
		f := c.read(t)
		if f.Type != "model" || len(f.MCPDiscovery) != 1 || len(f.MCPDiscovery[0].Tools) != 8 || f.MCPDiscovery[0].Tools[0].Name != tc.first || f.MCPTool != nil {
			t.Fatal("supplied discovery query or question fallback did not reach bounded initial ranking")
		}
		if f.DiscoveryQuery != "" || strings.Contains(jsonText(f), "PRIVATE_QUERY_MARKER") {
			t.Fatal("private ranking query was echoed in a model frame")
		}
		c.write(t, frame{Type: "reply", ID: f.ID, Content: "Metadata review complete."})
		if result := c.read(t); result.ToolCount != 0 || result.Type != "done" {
			t.Fatal("metadata ranking executed a tool")
		}
		if err := <-c.done; err != nil {
			t.Fatal(err)
		}
	}
	before := probes.Load()
	c := newClient(t)
	c.write(t, frame{Type: "start", Prompt: "Reject oversized ranking input.", DiscoveryQuery: strings.Repeat("紅", 2667),
		Tools:   []toolDefinition{{Name: "getMacContext", InputSchemaJSON: `{"type":"object"}`}, {Name: "inspectLocalFiles", InputSchemaJSON: `{"type":"object"}`}},
		Servers: []mcpServerConfig{{ID: "fixture", Name: "Fixture", Enabled: true, Transport: "http", URL: server.URL, AllowedTools: approvals}}})
	if err := <-c.done; err == nil || err.Error() != "invalid_start" || probes.Load() != before {
		t.Fatal("discovery query UTF-8 byte limit was not enforced before network discovery")
	}
}
