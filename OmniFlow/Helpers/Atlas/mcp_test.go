package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"
)

func fixtureHost(t *testing.T) (*mcpHost, *mcpConnection) {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	store, err := newPayloadStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	script, err := filepath.Abs("../../../tests/fixtures/mcp_server.py")
	if err != nil {
		t.Fatal(err)
	}
	host, err := newMCPHost([]mcpServerConfig{{ID: "fixture", Name: "Fixture", Command: "/opt/homebrew/bin/python3", Arguments: []string{script}, Enabled: true, AllowResources: true}}, store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { host.close(); store.close() })
	c, err := host.connect(context.Background(), "fixture")
	if err != nil {
		t.Fatal(err)
	}
	return host, c
}
func approveFixture(c *mcpConnection, name string) {
	tool := c.tools[name]
	c.config.AllowedTools = append(c.config.AllowedTools, mcpApproval{Name: name, Digest: tool.Digest})
}

func TestMCPLocalPaginationApprovalAndLargeResult(t *testing.T) {
	h, c := fixtureHost(t)
	if len(c.tools) != 3 {
		t.Fatal("catalog pagination lost tools")
	}
	args := map[string]interface{}{"operation": "call", "server": "fixture", "name": "read_archive", "argumentsJSON": "{}"}
	if _, err := h.execute(context.Background(), args); err == nil {
		t.Fatal("unapproved tool ran")
	}
	approveFixture(c, "read_archive")
	changed := c.tools["read_archive"]
	changed.Digest = strings.Repeat("0", 64)
	c.tools[changed.Name] = changed
	if _, err := h.execute(context.Background(), args); err == nil {
		t.Fatal("changed definition retained permission")
	}
	changed.Digest = c.config.AllowedTools[0].Digest
	c.tools[changed.Name] = changed
	args["argumentsJSON"] = `{"extra":"not approved"}`
	if _, err := h.execute(context.Background(), args); err == nil {
		t.Fatal("unexpected argument accepted")
	}
	args["argumentsJSON"] = "{}"
	result, err := h.execute(context.Background(), args)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.(string)) > 7000 || strings.Contains(result.(string), "release-comet-73") {
		t.Fatal("large result bypassed preview limit")
	}
	var envelope struct {
		Evidence struct {
			Payload payloadEntry `json:"payload"`
		} `json:"evidence"`
	}
	if json.Unmarshal([]byte(result.(string)), &envelope) != nil {
		t.Fatal("invalid evidence wrapper")
	}
	entry := envelope.Evidence.Payload
	if entry.Bytes < 1_000_000 || entry.Chunks < 500 || !entry.Suspicious {
		t.Fatal("payload or security metadata lost")
	}
	search, err := h.store.execute(context.Background(), map[string]interface{}{"operation": "search", "id": entry.ID, "query": "release-comet-73"})
	if err != nil || !strings.Contains(search.(string), "release-comet-73") || !strings.Contains(search.(string), `"scannedEndByte"`) {
		t.Fatal("tail evidence inaccessible")
	}
	if _, _, err := h.store.data("../../secret"); err == nil {
		t.Fatal("payload path traversal accepted")
	}
	h.store.question = "Search the returned archive for the phrase release label and tell me that label."
	preview := h.store.preview(h.store.entries[entry.ID])
	if !strings.Contains(preview, "release-comet-73") || !strings.Contains(preview, `"method":"local keyword relevance"`) {
		t.Fatal("question-aware retrieval did not surface the distant answer")
	}
}

func TestMCPProcessBoundariesAndHostRequests(t *testing.T) {
	h, c := fixtureHost(t)
	approveFixture(c, "probe_boundaries")
	outside := filepath.Join(t.TempDir(), "forbidden.txt")
	result, err := h.execute(context.Background(), map[string]interface{}{"operation": "call", "server": "fixture", "name": "probe_boundaries", "argumentsJSON": jsonText(map[string]string{"outside": outside})})
	if err != nil {
		t.Fatal(err)
	}
	// Decode wrappers rather than searching escaped JSON booleans.
	var envelope struct {
		Evidence struct {
			Text string `json:"text"`
		} `json:"evidence"`
	}
	if json.Unmarshal([]byte(result.(string)), &envelope) != nil {
		t.Fatal("missing evidence")
	}
	var checks struct {
		WriteBlocked          bool
		NetworkBlocked        bool
		TemporaryWriteAllowed bool
		EnvironmentKeys       []string
	}
	if json.Unmarshal([]byte(envelope.Evidence.Text), &checks) != nil || !checks.WriteBlocked || !checks.NetworkBlocked || !checks.TemporaryWriteAllowed {
		t.Fatalf("sandbox failed: %s", envelope.Evidence.Text)
	}
	for _, key := range checks.EnvironmentKeys {
		if strings.Contains(key, "TOKEN") || strings.Contains(key, "KEY") {
			t.Fatal("secret environment inherited")
		}
	}
	if _, err := os.Stat(outside); !os.IsNotExist(err) {
		t.Fatal("server wrote outside work folder")
	}
	response, err := c.transport.rpc(context.Background(), "fixture/host-request", map[string]interface{}{})
	if err != nil || !strings.Contains(string(response), `true`) {
		t.Fatal("server-initiated sampling was not refused")
	}
}

func TestMCPResourcesAndCancellation(t *testing.T) {
	h, c := fixtureHost(t)
	if _, err := h.execute(context.Background(), map[string]interface{}{"operation": "readResource", "server": "fixture", "name": "fixture://not-listed"}); err == nil {
		t.Fatal("undiscovered resource accepted")
	}
	if _, err := h.execute(context.Background(), map[string]interface{}{"operation": "resources", "server": "fixture"}); err != nil {
		t.Fatal(err)
	}
	result, err := h.execute(context.Background(), map[string]interface{}{"operation": "readResource", "server": "fixture", "name": "fixture://compressed"})
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Attachments []payloadEntry `json:"attachments"`
	}
	_ = json.Unmarshal([]byte(result.(string)), &envelope)
	if len(envelope.Attachments) != 1 {
		t.Fatal("decoded resource missing")
	}
	data, entry, err := h.store.data(envelope.Attachments[0].ID)
	if err != nil || !entry.Text || !strings.Contains(string(data), "紅熊猫") {
		t.Fatal("base64/gzip decoding failed")
	}
	approveFixture(c, "slow")
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	pid := c.transport.command.Process.Pid
	_, err = h.execute(ctx, map[string]interface{}{"operation": "call", "server": "fixture", "name": "slow", "argumentsJSON": "{}"})
	if err == nil || syscall.Kill(pid, 0) != syscall.ESRCH {
		t.Fatal("cancelled MCP process survived")
	}
}

func TestPayloadUTF8IntegrityQuotasAndSearchBoundaries(t *testing.T) {
	dir := t.TempDir()
	_ = os.Chmod(dir, 0700)
	s, err := newPayloadStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	text := strings.Repeat("a", chunkBytes-2) + "needle紅熊猫" + strings.Repeat("b", 5000)
	entry, err := s.put("fixture", []byte(text), true)
	if err != nil {
		t.Fatal(err)
	}
	data, _, err := s.data(entry.ID)
	if err != nil || string(data) != text {
		t.Fatal("compressed store was not lossless")
	}
	for i := 0; i < entry.Chunks; i++ {
		if !utf8.Valid(data[entry.offsets[i]:entry.offsets[i+1]]) {
			t.Fatal("split unicode scalar")
		}
	}
	result, err := s.execute(context.Background(), map[string]interface{}{"operation": "search", "id": entry.ID, "query": "needle紅熊猫"})
	if err != nil || !strings.Contains(result.(string), `"totalMatchesFromOffset":1`) {
		t.Fatal("cross-boundary match was lost")
	}
	if _, err := s.put("oversized", make([]byte, maxPayloadBytes+1), false); err == nil {
		t.Fatal("byte quota not enforced")
	}
	if _, err := s.execute(context.Background(), map[string]interface{}{"operation": "read", "id": entry.ID, "offset": -1.0}); err == nil {
		t.Fatal("negative offset accepted")
	}
	if err := os.WriteFile(filepath.Join(s.directory, entry.ID+".gz"), []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.data(entry.ID); err == nil {
		t.Fatal("corrupt payload accepted")
	}
	var encoded bytes.Buffer
	w := gzip.NewWriter(&encoded)
	_, _ = w.Write(make([]byte, maxPayloadBytes+1))
	_ = w.Close()
	if _, _, err := decodeResourceBlob(base64.StdEncoding.EncodeToString(encoded.Bytes()), "application/gzip"); err == nil {
		t.Fatal("decompression expansion limit bypassed")
	}
}

func TestSchemaFailsClosed(t *testing.T) {
	if numbersRoundTrip([]byte(`{"id":9007199254740993}`)) || !numbersRoundTrip([]byte(`{"id":42,"amount":0.1}`)) {
		t.Fatal("lossy numeric arguments were not detected")
	}
	for _, number := range []string{"1e-999999999999", "1e999999999999", "1e-400", "9007199254740993"} {
		if numbersRoundTrip([]byte(`{"value":` + number + `}`)) {
			t.Fatal("unsafe numeric representation accepted")
		}
	}
	var schema map[string]interface{}
	_ = json.Unmarshal([]byte(`{"type":"object","properties":{"mode":{"type":"string","enum":["read"]},"count":{"type":"integer","minimum":1,"maximum":3}},"required":["mode"],"additionalProperties":false}`), &schema)
	if !schemaSupported(schema, schema, 0) || !validateSchema(map[string]interface{}{"mode": "read", "count": 2.0}, schema, schema, 0) {
		t.Fatal("valid schema rejected")
	}
	for _, value := range []map[string]interface{}{{"mode": "write"}, {"count": 1.0}, {"mode": "read", "count": 4.0}, {"mode": "read", "extra": true}} {
		if validateSchema(value, schema, schema, 0) {
			t.Fatal("invalid arguments accepted")
		}
	}
	schema["unevaluatedProperties"] = false
	if schemaSupported(schema, schema, 0) {
		t.Fatal("unsupported validation keyword silently ignored")
	}
}

func TestStructuredContentPreservesNumericIdentifiers(t *testing.T) {
	h, c := fixtureHost(t)
	result, err := h.ingest(c, "fixture", json.RawMessage(`{"content":[],"structuredContent":{"id":9007199254740993}}`), false)
	if err != nil || !strings.Contains(result.(string), "9007199254740993") {
		t.Fatal("structured-content identifier was rounded")
	}
}

func TestMCPBrokerAuthenticationAndParentLifetime(t *testing.T) {
	directory := t.TempDir()
	_ = os.Chmod(directory, 0700)
	endpoint := mcpBrokerEndpoint{Socket: filepath.Join(directory, "s"), Token: strings.Repeat("a", 64)}
	// macOS AF_UNIX paths are short; Go's per-test temp directory can be longer.
	if len(endpoint.Socket) > 100 {
		var err error
		directory, err = os.MkdirTemp("/tmp", "nlm-test-")
		if err != nil {
			t.Fatal(err)
		}
		endpoint.Socket = filepath.Join(directory, "s")
		defer os.RemoveAll(directory)
	}
	input, output := io.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	finished := make(chan error, 1)
	go func() { finished <- serveMCPBroker(ctx, input) }()
	defer output.Close()
	if _, err := output.Write([]byte(jsonText(endpoint) + "\n")); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 100; attempt++ {
		if _, err := os.Stat(endpoint.Socket); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	bad, err := net.Dial("unix", endpoint.Socket)
	if err != nil {
		t.Fatal(err)
	}
	_ = bad.SetDeadline(time.Now().Add(time.Second))
	_, _ = bad.Write([]byte(`{"token":"wrong","config":{"command":"/usr/bin/true"}}` + "\n"))
	var one [1]byte
	if n, err := bad.Read(one[:]); n != 0 || err == nil {
		t.Fatal("unauthenticated launcher connection accepted")
	}
	_ = bad.Close()
	script, _ := filepath.Abs("../../../tests/fixtures/mcp_server.py")
	transport := &localMCPTransport{broker: &endpoint, config: mcpServerConfig{Command: "/opt/homebrew/bin/python3", Arguments: []string{script}}, ctx: ctx}
	if err := transport.Connect(); err != nil {
		t.Fatal(err)
	}
	defer transport.Close()
	raw, err := transport.rpc(ctx, "fixture/process", map[string]interface{}{})
	if err != nil {
		t.Fatal(err)
	}
	var process struct {
		PID int `json:"pid"`
	}
	_ = json.Unmarshal(raw, &process)
	if process.PID == 0 {
		t.Fatal("server did not start")
	}
	_ = output.Close()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("launcher survived parent EOF")
	}
	if syscall.Kill(process.PID, 0) != syscall.ESRCH {
		t.Fatal("MCP child survived launcher shutdown")
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("launcher scratch files survived shutdown")
	}
}

func TestCatalogChangeRevokesRunGrants(t *testing.T) {
	h, c := fixtureHost(t)
	approveFixture(c, "read_archive")
	if _, err := c.transport.rpc(context.Background(), "fixture/catalog-changed", map[string]interface{}{}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.execute(context.Background(), map[string]interface{}{"operation": "call", "server": "fixture", "name": "read_archive", "argumentsJSON": "{}"}); err == nil {
		t.Fatal("catalog notification did not revoke grants")
	}
}
