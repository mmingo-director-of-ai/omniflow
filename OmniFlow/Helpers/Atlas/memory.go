package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

const analysisBytes = 16000
const analysisBatch = 8
const maxAnalysisPasses = 4096
const maxMemoryBytes = 16 * 1024 * 1024

// Derived notes are untrusted evidence, never instructions or authorization.
// Exact excerpts and parent IDs let a later window recover their provenance.
type memorySource struct {
	ID    string `json:"id"`
	Start int    `json:"startByte"`
	End   int    `json:"endByte"`
	Quote string `json:"quote,omitempty"`
}
type memoryRecord struct {
	ID      string         `json:"id"`
	Text    string         `json:"text"`
	Sources []memorySource `json:"sources,omitempty"`
	Parents []string       `json:"parents,omitempty"`
}
type analysisJob struct {
	ID       string   `json:"id"`
	Goal     string   `json:"goal"`
	Cursor   int      `json:"processedBytes"`
	Total    int      `json:"totalBytes"`
	Level    []string `json:"level"`
	Next     []string `json:"next"`
	Reduced  int      `json:"reduced"`
	Complete bool     `json:"complete"`
	Result   string   `json:"result,omitempty"`
}
type memoryView struct {
	Records    []memoryRecord `json:"records"`
	Operations []string       `json:"recentOperations,omitempty"`
	Total      int            `json:"totalRecords"`
	Passes     int            `json:"analysisPasses"`
	Active     *analysisJob   `json:"active,omitempty"`
}
type analysisRequest struct {
	Phase   string         `json:"phase"`
	Goal    string         `json:"goal"`
	Focus   string         `json:"focus,omitempty"`
	ID      string         `json:"id"`
	Start   int            `json:"startByte"`
	Total   int            `json:"totalBytes"`
	Text    string         `json:"text,omitempty"`
	Records []memoryRecord `json:"records,omitempty"`
}
type analysisReply struct {
	Text    string   `json:"text"`
	Quotes  []string `json:"quotes"`
	Bytes   int      `json:"consumedBytes"`
	Records int      `json:"consumedRecords"`
}
type taskMemory struct {
	bridge   *bridge
	records  []memoryRecord
	receipts []string
	jobs     map[string]*analysisJob
	active   string
	passes   int
	bytes    int
	broken   bool
}

func newTaskMemory(b *bridge) *taskMemory {
	return &taskMemory{bridge: b, jobs: make(map[string]*analysisJob)}
}

// One append commits the note and its cursor together. Model-window resets
// never replay a completed source slice or an external MCP operation.
func (m *taskMemory) commit(record *memoryRecord, job *analysisJob) error {
	if m.broken || (record != nil && len(m.records) >= 8192) {
		return errors.New("task_memory_limit")
	}
	event := struct {
		Record *memoryRecord `json:"record,omitempty"`
		Job    *analysisJob  `json:"job,omitempty"`
	}{record, job}
	if err := m.appendEvent(event); err != nil {
		return err
	}
	if record != nil {
		m.records = append(m.records, *record)
	}
	if job != nil {
		m.jobs[job.ID] = job
	}
	return nil
}

func (m *taskMemory) appendEvent(event interface{}) error {
	if m.broken {
		return errors.New("task_memory_limit")
	}
	data, err := json.Marshal(event)
	if err != nil || m.bytes+len(data)+1 > maxMemoryBytes {
		return errors.New("task_memory_limit")
	}
	f, err := os.OpenFile(filepath.Join(m.bridge.store.directory, "task-memory.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return errors.New("task_memory_write_failed")
	}
	_, writeErr := f.Write(append(data, '\n'))
	if writeErr == nil && m.bridge.store.persistent {
		writeErr = f.Sync()
	}
	closeErr := f.Close()
	if writeErr != nil || closeErr != nil {
		m.broken = true
		return errors.New("task_memory_write_failed")
	}
	m.bytes += len(data) + 1
	return nil
}

func (m *taskMemory) record(id string) *memoryRecord {
	for i := range m.records {
		if m.records[i].ID == id {
			return &m.records[i]
		}
	}
	return nil
}

func (m *taskMemory) receipt(name string, args map[string]interface{}, success bool) error {
	label := name
	for _, key := range []string{"operation", "server"} {
		if value, ok := args[key].(string); ok && value != "" {
			label += " " + utf8Prefix(value, 80)
		}
	}
	if name == "mcp" && (args["operation"] == "call" || args["operation"] == "schema") {
		if value, ok := args["name"].(string); ok {
			label += " " + utf8Prefix(value, 160)
		}
	}
	status := "completed"
	if !success {
		status = "reported an error; its remote outcome may be unknown"
	}
	receipt := label + " " + status
	if err := m.appendEvent(map[string]interface{}{"operationReceipt": receipt}); err != nil {
		return err
	}
	m.receipts = append(m.receipts, receipt)
	return nil
}

func (m *taskMemory) view(query string) memoryView {
	return m.page(query, 0)
}

func (m *taskMemory) page(query string, offset int) memoryView {
	view := memoryView{Records: []memoryRecord{}, Total: len(m.records), Passes: m.passes}
	view.Operations = m.receipts[max(0, len(m.receipts)-8):]
	if job := m.jobs[m.active]; job != nil {
		// The potentially large reduction queues stay outside the model window.
		view.Active = &analysisJob{ID: job.ID, Cursor: job.Cursor, Total: job.Total, Complete: job.Complete, Result: job.Result}
	}
	type candidate struct{ index, score int }
	var ranked []candidate
	terms := strings.Fields(strings.ToLower(query))
	for i, record := range m.records {
		score := 0
		for _, term := range terms {
			if len(term) >= 3 && strings.Contains(strings.ToLower(record.Text), term) {
				score++
			}
		}
		if view.Active != nil && record.ID == view.Active.Result {
			score += 1000
		}
		ranked = append(ranked, candidate{i, score})
	}
	sort.SliceStable(ranked, func(i, j int) bool {
		if ranked[i].score != ranked[j].score {
			return ranked[i].score > ranked[j].score
		}
		return ranked[i].index > ranked[j].index
	})
	remaining := 5000
	for _, candidate := range ranked[offset:] {
		if len(view.Records) == 6 || remaining < 400 {
			break
		}
		record := m.records[candidate.index]
		record.Text = utf8Prefix(record.Text, min(1600, remaining-300))
		record.Sources = nil // memory.read returns exact excerpts and parent links.
		record.Parents = nil
		remaining -= len(record.Text) + 100
		view.Records = append(view.Records, record)
	}
	return view
}

func (m *taskMemory) execute(ctx context.Context, args map[string]interface{}) (interface{}, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	op, _ := args["operation"].(string)
	id, _ := args["id"].(string)
	query, _ := args["query"].(string)
	if len(query) > 8000 {
		return nil, errors.New("task_query_limit")
	}
	switch op {
	case "search", "status":
		offset, err := integerArgument(args, "offset", 0, len(m.records))
		if err != nil {
			return nil, err
		}
		if query == "" {
			query = m.bridge.store.question
		}
		page := m.page(query, offset)
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "memory": page, "nextOffset": offset + len(page.Records),
			"hasMore": offset+len(page.Records) < len(m.records), "coverage": "Selected derived notes, not all evidence. Follow nextOffset for more notes; read note IDs to recover quotes and parent notes."}), nil
	case "read":
		record := m.record(id)
		if record == nil {
			return nil, errors.New("unknown_memory_reference")
		}
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "record": record}), nil
	case "remember":
		quote, _ := args["quote"].(string)
		if len(quote) == 0 || len(quote) > 2000 {
			return nil, errors.New("memory_quote_required_max_2000_bytes")
		}
		data, entry, err := m.bridge.store.data(id)
		if err != nil {
			return nil, err
		}
		if !entry.Text || entry.Kind == "schema" {
			return nil, errors.New("memory_requires_source_text")
		}
		position := bytes.Index(data, []byte(quote))
		if position < 0 {
			return nil, errors.New("memory_quote_not_in_source")
		}
		for _, record := range m.records {
			if record.Text == quote && len(record.Sources) == 1 && record.Sources[0].ID == id {
				return jsonText(map[string]interface{}{"trust": "untrusted_data", "record": record}), nil
			}
		}
		record := &memoryRecord{ID: fmt.Sprintf("m%d", len(m.records)+1), Text: quote,
			Sources: []memorySource{{ID: id, Start: position, End: position + len(quote), Quote: quote}}}
		if err := m.commit(record, nil); err != nil {
			return nil, err
		}
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "record": record}), nil
	case "analyze":
		return m.analyze(ctx, id, query)
	default:
		return nil, errors.New("unknown_memory_operation")
	}
}

func (m *taskMemory) analyze(ctx context.Context, id, goal string) (interface{}, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	data, entry, err := m.bridge.store.data(id)
	if err != nil {
		return nil, err
	}
	if !entry.Text || entry.Kind == "schema" {
		return nil, errors.New("memory_requires_source_text")
	}
	job := m.jobs[id]
	if goal == "" {
		if job != nil {
			goal = job.Goal
		} else {
			goal = m.bridge.store.question
		}
	}
	if job != nil && goal != job.Goal {
		return nil, errors.New("analysis_goal_already_pinned")
	}
	if job == nil {
		job = &analysisJob{ID: id, Goal: goal, Total: len(data), Level: []string{}, Next: []string{}}
		if err := m.commit(nil, job); err != nil {
			return nil, err
		}
	}
	m.active = id
	for batch := 0; batch < analysisBatch && !job.Complete; batch++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		next := *job
		next.Level = append([]string{}, job.Level...)
		next.Next = append([]string{}, job.Next...)
		request := analysisRequest{Goal: goal, ID: id, Total: len(data)}
		if m.bridge.store.question != "" {
			request.Goal = m.bridge.store.question
			if goal != request.Goal {
				request.Focus = goal
			}
		}
		if job.Cursor < len(data) {
			request.Phase = "extract"
			request.Start = max(0, job.Cursor-320)
			for request.Start < job.Cursor && !utf8.RuneStart(data[request.Start]) {
				request.Start++
			}
			request.Text = utf8Prefix(string(data[request.Start:]), analysisBytes)
		} else {
			if next.Reduced == len(next.Level) {
				next.Level, next.Next, next.Reduced = next.Next, []string{}, 0
			}
			if len(next.Level) <= 1 {
				next.Complete = true
				if len(next.Level) == 1 {
					next.Result = next.Level[0]
				}
				if err := m.commit(nil, &next); err != nil {
					return nil, err
				}
				job = &next
				break
			}
			request.Phase = "merge"
			for _, recordID := range next.Level[next.Reduced:min(next.Reduced+4, len(next.Level))] {
				record := *m.record(recordID)
				record.Sources, record.Parents = nil, nil
				request.Records = append(request.Records, record)
			}
			// Carry a single remaining node to the next level without inference.
			if len(request.Records) == 1 {
				next.Next = append(next.Next, request.Records[0].ID)
				next.Reduced++
				if err := m.commit(nil, &next); err != nil {
					return nil, err
				}
				job = &next
				continue
			}
		}
		if m.passes >= maxAnalysisPasses {
			return nil, errors.New("analysis_pass_limit")
		}
		m.passes++
		reply, err := m.bridge.exchange(ctx, frame{Type: "analysis", Step: m.bridge.step, Analysis: &request})
		if err != nil {
			return nil, err
		}
		if reply.AnalysisError != "" {
			return nil, errors.New("analysis_generation_failed_checkpoint_retained")
		}
		result := reply.AnalysisResult
		if result == nil || len(reply.ToolCalls) != 0 || len(result.Text) > 2400 || len(result.Quotes) > 4 {
			return nil, errors.New("invalid_analysis_result")
		}
		record := &memoryRecord{ID: fmt.Sprintf("m%d", len(m.records)+1), Text: result.Text}
		if request.Phase == "extract" {
			if result.Bytes <= job.Cursor-request.Start || result.Bytes > len(request.Text) || result.Records != 0 ||
				!utf8.ValidString(request.Text[:result.Bytes]) || (result.Text != "" && len(result.Quotes) == 0) {
				return nil, errors.New("invalid_analysis_coverage")
			}
			for _, quote := range result.Quotes {
				position := strings.Index(request.Text[:result.Bytes], quote)
				if quote == "" || len(quote) > 800 || position < 0 {
					return nil, errors.New("analysis_quote_not_in_source")
				}
				record.Sources = append(record.Sources, memorySource{ID: id, Start: request.Start + position, End: request.Start + position + len(quote), Quote: quote})
			}
			next.Cursor = request.Start + result.Bytes
			if result.Text != "" {
				next.Level = append(next.Level, record.ID)
			} else {
				record = nil
			}
		} else {
			if result.Records < 2 || result.Records > len(request.Records) || result.Bytes != 0 || result.Text == "" || len(result.Quotes) != 0 {
				return nil, errors.New("invalid_analysis_merge")
			}
			for _, parent := range request.Records[:result.Records] {
				record.Parents = append(record.Parents, parent.ID)
			}
			next.Reduced += result.Records
			next.Next = append(next.Next, record.ID)
		}
		if err := m.commit(record, &next); err != nil {
			return nil, err
		}
		job = &next
	}
	result := map[string]interface{}{"trust": "untrusted_data", "payloadID": id, "processedBytes": job.Cursor,
		"totalBytes": job.Total, "complete": job.Complete, "memory": m.view(goal),
		"coverage": "Processed bytes were presented to bounded extraction passes. Derived summaries can omit details; this is not proof of exhaustive understanding. Recover exact evidence with memory.read and payload.read/search."}
	return jsonText(result), nil
}
