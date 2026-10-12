package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type payloadCoverageResult struct {
	Payload       payloadEntry `json:"payload"`
	CompleteText  bool         `json:"completeText"`
	AllChunksRead bool         `json:"allChunksRead"`
	Coverage      string       `json:"coverage"`
	Text          *string      `json:"text"`
	StartByte     int          `json:"startByte"`
	EndByte       int          `json:"endByte"`
	Chunk         int          `json:"chunk"`
	HasMore       bool         `json:"hasMore"`
}

func coverageStore(t *testing.T) *payloadStore {
	t.Helper()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	store, err := newPayloadStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.close)
	return store
}

func decodeCoverage(t *testing.T, value string) payloadCoverageResult {
	t.Helper()
	var result payloadCoverageResult
	if err := json.Unmarshal([]byte(value), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func readCoverage(t *testing.T, store *payloadStore, entry *payloadEntry, chunk int) payloadCoverageResult {
	t.Helper()
	value, err := store.execute(context.Background(), map[string]interface{}{
		"operation": "read", "id": entry.ID, "offset": float64(chunk),
	})
	if err != nil {
		t.Fatal(err)
	}
	return decodeCoverage(t, value.(string))
}

func TestPayloadCoverageCompleteSingleChunk(t *testing.T) {
	store := coverageStore(t)
	text := `{"services":["calendar","mail","files","monitoring","紅熊猫","notes"]}`
	entry, err := store.put("tool-result", []byte(text), true)
	if err != nil {
		t.Fatal(err)
	}
	for _, result := range []payloadCoverageResult{
		decodeCoverage(t, store.preview(entry)),
		readCoverage(t, store, entry, 0),
		decodeCoverage(t, store.preview(entry)),
	} {
		if !result.CompleteText || !result.AllChunksRead || result.Text == nil || *result.Text != text {
			t.Fatal("complete result was reported as partial or its text changed")
		}
		if result.StartByte != 0 || result.EndByte != len(text) || result.Payload.Viewed != 1 || result.Payload.Chunks != 1 {
			t.Fatal("single-chunk byte coverage or unique read count was incorrect")
		}
		if !strings.Contains(result.Coverage, "Complete returned payload text") || strings.Contains(result.Coverage, "Preview only") {
			t.Fatal("coverage wording contradicted the complete returned text")
		}
	}
}

func TestPayloadCoveragePartialAndCumulativeReads(t *testing.T) {
	store := coverageStore(t)
	text := strings.Repeat("a", chunkBytes) + strings.Repeat("b", chunkBytes) + "distant-answer"
	entry, err := store.put("large-result", []byte(text), true)
	if err != nil {
		t.Fatal(err)
	}
	store.question = "distant-answer"
	preview := decodeCoverage(t, store.preview(entry))
	if preview.Chunk != 2 || preview.CompleteText || preview.AllChunksRead || preview.Payload.Viewed != 1 || preview.Text == nil || *preview.Text != "distant-answer" {
		t.Fatal("relevant final chunk was confused with complete payload coverage")
	}
	last := readCoverage(t, store, entry, 2)
	if last.HasMore || last.CompleteText || last.AllChunksRead || last.Payload.Viewed != 1 {
		t.Fatal("last-chunk navigation or repeated read overstated cumulative coverage")
	}
	if _, err := store.execute(context.Background(), map[string]interface{}{
		"operation": "search", "id": entry.ID, "query": "a",
	}); err != nil {
		t.Fatal(err)
	}
	if entry.Viewed != 1 {
		t.Fatal("search counted snippets as fully read chunks")
	}
	first := readCoverage(t, store, entry, 0)
	if first.CompleteText || first.AllChunksRead || first.Payload.Viewed != 2 || !first.HasMore {
		t.Fatal("partial cumulative coverage was incorrect")
	}
	middle := readCoverage(t, store, entry, 1)
	if middle.CompleteText || !middle.AllChunksRead || middle.Payload.Viewed != 3 || !middle.HasMore {
		t.Fatal("cumulative coverage was confused with the current response or navigation")
	}
	if middle.StartByte != chunkBytes || middle.EndByte != 2*chunkBytes || middle.Text == nil || *middle.Text != text[middle.StartByte:middle.EndByte] {
		t.Fatal("byte ranges did not match delivered text")
	}
	if !strings.Contains(middle.Coverage, "across this run") || !strings.Contains(middle.Coverage, "only the indicated byte range") {
		t.Fatal("cumulative coverage wording implied all text was in the current response")
	}
	repeated := decodeCoverage(t, store.preview(entry))
	if repeated.CompleteText || !repeated.AllChunksRead || repeated.Payload.Viewed != 3 {
		t.Fatal("repeat preview changed unique chunk coverage")
	}
}

func TestPayloadCoverageSchemaBinaryEmptyAndUnavailable(t *testing.T) {
	store := coverageStore(t)
	schema, err := store.put("tool-schema", []byte(`{"type":"object","properties":{}}`), true)
	if err != nil {
		t.Fatal(err)
	}
	schema.Kind = "schema"
	for _, result := range []payloadCoverageResult{decodeCoverage(t, store.preview(schema)), readCoverage(t, store, schema, 0)} {
		if !result.CompleteText || !strings.Contains(result.Coverage, "Schema metadata only") || !strings.Contains(result.Coverage, "not a tool execution result") {
			t.Fatal("complete schema was not distinguished from execution evidence")
		}
	}
	binary, err := store.put("binary", []byte{0, 255, 42}, false)
	if err != nil {
		t.Fatal(err)
	}
	binaryResult := decodeCoverage(t, store.preview(binary))
	if binaryResult.CompleteText || binaryResult.AllChunksRead || binaryResult.Text != nil || !strings.Contains(binaryResult.Coverage, "Binary payload metadata only") {
		t.Fatal("binary metadata claimed decoded text coverage")
	}
	empty, err := store.put("empty-text", nil, true)
	if err != nil {
		t.Fatal(err)
	}
	emptyResult := decodeCoverage(t, store.preview(empty))
	if !emptyResult.CompleteText || !emptyResult.AllChunksRead || emptyResult.Text == nil || *emptyResult.Text != "" || emptyResult.Payload.Viewed != 0 || emptyResult.EndByte != 0 {
		t.Fatal("verified empty text was not represented as complete empty content")
	}
	if err := os.WriteFile(filepath.Join(store.directory, schema.ID+".gz"), []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	unavailable := decodeCoverage(t, store.preview(schema))
	if unavailable.CompleteText || unavailable.AllChunksRead || unavailable.Text != nil || !strings.Contains(unavailable.Coverage, "unavailable") {
		t.Fatal("failed integrity check claimed available text coverage")
	}
}
