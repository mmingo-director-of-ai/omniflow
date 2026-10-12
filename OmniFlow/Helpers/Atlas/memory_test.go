package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

type analysisWriter func([]byte) (int, error)

func (f analysisWriter) Write(p []byte) (int, error) { return f(p) }

func memoryFixture(t *testing.T, respond func(analysisRequest) frame) *taskMemory {
	t.Helper()
	store, err := newPayloadStore("")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.close)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	inbound := make(chan input, 1)
	b := &bridge{store: store, in: inbound, cancel: cancel, requestID: "memory-test"}
	b.out = json.NewEncoder(analysisWriter(func(data []byte) (int, error) {
		var request frame
		if err := json.Unmarshal(data, &request); err != nil {
			t.Fatal(err)
		}
		if request.Type != "analysis" || request.Analysis == nil {
			t.Fatalf("unexpected callback: %s", request.Type)
		}
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		reply := respond(*request.Analysis)
		reply.Type, reply.Version, reply.RequestID, reply.ID = "reply", protocolVersion, request.RequestID, request.ID
		inbound <- input{frame: reply}
		return len(data), nil
	}))
	b.memory = newTaskMemory(b)
	return b.memory
}

func TestLargeAnalysisChainsAndKeepsSourceLineage(t *testing.T) {
	markers := []string{"First decision: staging only.", "Middle decision: 17 checks remain.", "Final decision: production is NOT approved."}
	source := markers[0] + strings.Repeat(" alpha", 256000) + "\n" + markers[1] + strings.Repeat(" beta", 256000) + "\n" + markers[2]
	var ranges [][2]int
	memory := memoryFixture(t, func(request analysisRequest) frame {
		result := &analysisReply{Quotes: []string{}}
		if request.Phase == "extract" {
			if len(request.Text) > analysisBytes || !utf8.ValidString(request.Text) {
				t.Fatal("unbounded or invalid source slice")
			}
			// Simulate a tokenizer admitting less than the offered source.
			text := utf8Prefix(request.Text, 11000)
			result.Bytes = len(text)
			ranges = append(ranges, [2]int{request.Start, request.Start + result.Bytes})
			for _, marker := range markers {
				if strings.Contains(text, marker) {
					result.Text += marker + " "
					result.Quotes = append(result.Quotes, marker)
				}
			}
		} else {
			result.Records = min(2, len(request.Records)) // exercise more than one reduction level
			for _, note := range request.Records[:result.Records] {
				result.Text += note.Text
			}
		}
		return frame{AnalysisResult: result}
	})
	entry, err := memory.bridge.store.put("large-source", []byte(source), true)
	if err != nil {
		t.Fatal(err)
	}
	for calls := 0; ; calls++ {
		if calls > 100 {
			t.Fatal("analysis failed to converge")
		}
		if _, err := memory.analyze(context.Background(), entry.ID, "Preserve every decision"); err != nil {
			t.Fatal(err)
		}
		job := memory.jobs[entry.ID]
		if job.Complete {
			break
		}
		// The host, rather than the model, must schedule the continuation.
		next, err := memory.bridge.Generate(context.Background(), nil, nil)
		if err != nil || len(next.ToolCalls) != 1 || next.ToolCalls[0].Name != "memory" || next.ToolCalls[0].Arguments["id"] != entry.ID {
			t.Fatal("analysis did not continue against the same stored payload")
		}
	}
	job := memory.jobs[entry.ID]
	if job.Cursor != len(source) || memory.passes <= 24 {
		t.Fatal("source did not cross many model windows")
	}
	end := 0
	for _, span := range ranges {
		if span[0] > end || span[1] <= end {
			t.Fatal("a source region was skipped or failed to progress")
		}
		end = span[1]
	}
	root := memory.record(job.Result)
	if root == nil || len(root.Parents) < 2 {
		t.Fatal("missing cumulative synthesis")
	}
	for _, marker := range markers {
		if !strings.Contains(root.Text, marker) {
			t.Fatalf("lost decision: %s", marker)
		}
	}
	var verify func(string)
	verify = func(id string) {
		note := memory.record(id)
		if note == nil {
			t.Fatal("broken note reference")
		}
		for _, reference := range note.Sources {
			if source[reference.Start:reference.End] != reference.Quote {
				t.Fatal("provenance did not resolve exactly")
			}
		}
		for _, parent := range note.Parents {
			verify(parent)
		}
	}
	verify(root.ID)
	journal, err := os.ReadFile(filepath.Join(memory.bridge.store.directory, "task-memory.jsonl"))
	if err != nil || !strings.Contains(string(journal), `"complete":true`) {
		t.Fatal("completion was not checkpointed")
	}
}

func TestAnalysisRejectsInventedEvidenceWithoutAdvancing(t *testing.T) {
	valid := false
	memory := memoryFixture(t, func(request analysisRequest) frame {
		quote := "invented evidence"
		if valid {
			quote = "Deployment is NOT approved."
		}
		return frame{AnalysisResult: &analysisReply{Text: "Deployment is NOT approved.", Quotes: []string{quote}, Bytes: len(request.Text)}}
	})
	entry, _ := memory.bridge.store.put("fixture", []byte("Deployment is NOT approved."), true)
	if _, err := memory.analyze(context.Background(), entry.ID, "approval"); err == nil {
		t.Fatal("invented evidence accepted")
	}
	if memory.jobs[entry.ID].Cursor != 0 || len(memory.records) != 0 {
		t.Fatal("failed extraction advanced the checkpoint")
	}
	valid = true
	if _, err := memory.analyze(context.Background(), entry.ID, ""); err != nil {
		t.Fatal(err)
	}
	if !memory.jobs[entry.ID].Complete || len(memory.records) != 1 {
		t.Fatal("retry did not resume exactly once")
	}
	if _, err := memory.analyze(context.Background(), entry.ID, "different goal"); err == nil {
		t.Fatal("checkpoint silently reused for a different goal")
	}
}

func TestAnalysisFailureAndCancellationKeepPriorProgress(t *testing.T) {
	fail := false
	memory := memoryFixture(t, func(request analysisRequest) frame {
		if fail {
			return frame{AnalysisError: "analysis_generation_failed"}
		}
		fail = true
		return frame{AnalysisResult: &analysisReply{Bytes: len(request.Text), Quotes: []string{}}}
	})
	entry, _ := memory.bridge.store.put("fixture", []byte(strings.Repeat("café 紅熊猫.\n", 10000)), true)
	if _, err := memory.analyze(context.Background(), entry.ID, "find a decision"); err == nil {
		t.Fatal("failure was not reported")
	}
	cursor := memory.jobs[entry.ID].Cursor
	if cursor == 0 || cursor == entry.Bytes {
		t.Fatal("bad partial checkpoint")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := memory.analyze(ctx, entry.ID, "find a decision"); err == nil {
		t.Fatal("cancelled analysis continued")
	}
	if memory.jobs[entry.ID].Cursor != cursor {
		t.Fatal("failed pass advanced the source cursor")
	}
}

func TestRememberedFactsSurviveWindowSelection(t *testing.T) {
	memory := memoryFixture(t, func(analysisRequest) frame { t.Fatal("remember should not invoke a model"); return frame{} })
	var source strings.Builder
	for i := 0; i < 40; i++ {
		fmt.Fprintf(&source, "Fact %d: retain exact identifier item-%04d.\n", i, i)
	}
	entry, _ := memory.bridge.store.put("fixture", []byte(source.String()), true)
	for _, quote := range strings.Split(strings.TrimSpace(source.String()), "\n") {
		if _, err := memory.execute(context.Background(), map[string]interface{}{"operation": "remember", "id": entry.ID, "quote": quote}); err != nil {
			t.Fatal(err)
		}
	}
	view := memory.view("unrelated")
	if len(view.Records) >= len(memory.records) {
		t.Fatal("memory was not bounded")
	}
	seen := map[string]bool{}
	for offset := 0; offset < len(memory.records); {
		page := memory.page("unrelated", offset)
		if len(page.Records) == 0 {
			t.Fatal("pagination stopped before the end")
		}
		for _, note := range page.Records {
			seen[note.ID] = true
		}
		offset += len(page.Records)
	}
	if len(seen) != len(memory.records) {
		t.Fatal("some findings cannot be retrieved through pagination")
	}
	old, err := memory.execute(context.Background(), map[string]interface{}{"operation": "read", "id": "m1"})
	if err != nil || !strings.Contains(old.(string), "item-0000") {
		t.Fatal("early finding was lost")
	}
	if _, err := memory.execute(context.Background(), map[string]interface{}{"operation": "remember", "id": entry.ID, "quote": "unverified"}); err == nil {
		t.Fatal("unverified quote accepted")
	}
	if err := memory.receipt("mcp", map[string]interface{}{"operation": "call", "name": "create_item", "server": "s1"}, true); err != nil {
		t.Fatal(err)
	}
	if len(memory.records) != len(seen) || len(memory.view("").Operations) != 1 || !strings.Contains(memory.receipts[0], "create_item completed") {
		t.Fatal("completed operation was not retained")
	}
}

func TestMCPErrorResultIsNotRememberedAsSuccess(t *testing.T) {
	b := &bridge{}
	tool := localTool{bridge: b, name: "mcp", execute: func(context.Context, map[string]interface{}) (interface{}, error) {
		return `{"isError":true,"evidence":{"text":"fixture failure"}}`, nil
	}}
	if _, err := tool.Execute(context.Background(), map[string]interface{}{"operation": "call"}); err != nil {
		t.Fatal(err)
	}
	if b.previousError != "mcp_tool_reported_error" {
		t.Fatal("server-reported error would be recorded as successful execution")
	}
}

func TestAnalysisFocusCannotReplaceOriginalUserGoal(t *testing.T) {
	const goal = "Summarize staging and production restrictions."
	const evidence = "Staging is permitted. Production is not approved."
	memory := memoryFixture(t, func(request analysisRequest) frame {
		if request.Goal != goal || request.Focus != "staging" {
			t.Fatal("a narrow model query replaced the original user goal")
		}
		return frame{AnalysisResult: &analysisReply{Text: evidence, Quotes: []string{evidence}, Bytes: len(request.Text)}}
	})
	memory.bridge.store.question = goal
	entry, _ := memory.bridge.store.put("fixture", []byte(evidence), true)
	if _, err := memory.analyze(context.Background(), entry.ID, "staging"); err != nil {
		t.Fatal(err)
	}
}
