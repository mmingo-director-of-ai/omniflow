package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

// Connection credentials and MCP grants are not serialized here. Durable
// workspaces contain source evidence; resuming restores local analysis only.
func (s *payloadStore) persistIndex() error {
	if !s.persistent {
		return nil
	}
	entries := make([]*payloadEntry, 0, len(s.order))
	for _, id := range s.order {
		entries = append(entries, s.entries[id])
	}
	data, err := json.Marshal(struct {
		Version  int             `json:"version"`
		Question string          `json:"question"`
		Entries  []*payloadEntry `json:"entries"`
	}{1, s.question, entries})
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(s.directory, ".index-")
	if err != nil {
		return errors.New("checkpoint_write_failed")
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return errors.New("checkpoint_write_failed")
	}
	if err = os.Rename(file.Name(), filepath.Join(s.directory, "payload-index.json")); err != nil {
		return errors.New("checkpoint_write_failed")
	}
	return nil
}

func (s *payloadStore) enablePersistence(resume bool) error {
	// Even a failed lock/restore must never delete somebody else's workspace.
	s.persistent = true
	f, err := os.OpenFile(filepath.Join(s.directory, ".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return errors.New("checkpoint_unavailable")
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return errors.New("checkpoint_in_use")
	}
	s.lock, s.persistent = f, true
	if !resume {
		if _, err := os.Stat(filepath.Join(s.directory, "payload-index.json")); !os.IsNotExist(err) {
			return errors.New("checkpoint_already_exists")
		}
		return s.persistIndex()
	}
	data, err := readCheckpointFile(s.directory, "payload-index.json", 256*1024)
	if err != nil {
		return err
	}
	var index struct {
		Version  int             `json:"version"`
		Question string          `json:"question"`
		Entries  []*payloadEntry `json:"entries"`
	}
	if json.Unmarshal(data, &index) != nil || index.Version != 1 || index.Question != s.question || len(index.Entries) > 128 {
		return errors.New("invalid_checkpoint")
	}
	for i, entry := range index.Entries {
		if entry == nil || entry.ID != fmt.Sprintf("p%d", i+1) || entry.Bytes < 0 || entry.Bytes > maxPayloadBytes ||
			(entry.Kind != "schema" && entry.Kind != "text" && entry.Kind != "binary") || entry.Text != (entry.Kind != "binary") ||
			len(entry.SHA256) != 64 || s.used+entry.Bytes > maxStoreBytes {
			return errors.New("invalid_checkpoint")
		}
		s.entries[entry.ID] = entry
		// data() verifies the gzip size and SHA-256 before rebuilding offsets.
		content, _, err := s.data(entry.ID)
		if err != nil || len(content) != entry.Bytes || (entry.Text && !utf8.Valid(content)) {
			return errors.New("invalid_checkpoint")
		}
		entry.seen = make(map[int]bool)
		entry.Viewed = 0 // Do not claim that a previous process read all text.
		entry.offsets = []int{0}
		if entry.Text {
			for start := 0; start < len(content); {
				end := min(start+chunkBytes, len(content))
				if end < len(content) {
					if newline := bytes.LastIndexByte(content[start:end], '\n'); newline >= chunkBytes/2 {
						end = start + newline + 1
					}
					for end > start && content[end]&0xc0 == 0x80 {
						end--
					}
				}
				entry.offsets = append(entry.offsets, end)
				start = end
			}
		}
		entry.Chunks = len(entry.offsets) - 1
		s.order = append(s.order, entry.ID)
		s.used += entry.Bytes
	}
	return nil
}

func readCheckpointFile(directory, name string, limit int64) ([]byte, error) {
	path := filepath.Join(directory, name)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("invalid_checkpoint")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("checkpoint_unavailable")
	}
	return data, nil
}

func (m *taskMemory) restore() error {
	data, err := readCheckpointFile(m.bridge.store.directory, "task-memory.jsonl", maxMemoryBytes)
	if err != nil {
		return err
	}
	// A process can die partway through the final append. Only complete lines
	// were committed; discard that tail before accepting any new checkpoint.
	committed := bytes.LastIndexByte(data, '\n') + 1
	scanner := bufio.NewScanner(bytes.NewReader(data[:committed]))
	scanner.Buffer(make([]byte, 4096), 256*1024)
	sources := make(map[string][]byte)
	for scanner.Scan() {
		var event struct {
			Record  *memoryRecord `json:"record"`
			Job     *analysisJob  `json:"job"`
			Receipt string        `json:"operationReceipt"`
		}
		if json.Unmarshal(scanner.Bytes(), &event) != nil {
			return errors.New("invalid_checkpoint")
		}
		if record := event.Record; record != nil {
			if len(m.records) >= 8192 || record.ID != fmt.Sprintf("m%d", len(m.records)+1) || len(record.Text) > 2400 || len(record.Sources) > 4 || len(record.Parents) > 4 {
				return errors.New("invalid_checkpoint")
			}
			for _, source := range record.Sources {
				entry := m.bridge.store.entries[source.ID]
				if entry == nil || !entry.Text || entry.Kind == "schema" || source.Start < 0 || source.End <= source.Start || source.End > entry.Bytes || source.End-source.Start != len(source.Quote) {
					return errors.New("invalid_checkpoint")
				}
				content, exists := sources[source.ID]
				if !exists {
					var err error
					content, _, err = m.bridge.store.data(source.ID)
					if err != nil {
						return errors.New("invalid_checkpoint")
					}
					sources[source.ID] = content
				}
				if string(content[source.Start:source.End]) != source.Quote {
					return errors.New("invalid_checkpoint")
				}
			}
			for _, parent := range record.Parents {
				if m.record(parent) == nil {
					return errors.New("invalid_checkpoint")
				}
			}
			m.records = append(m.records, *record)
		}
		if event.Receipt != "" {
			if len(event.Receipt) > 1000 || len(m.receipts) > 256 {
				return errors.New("invalid_checkpoint")
			}
			m.receipts = append(m.receipts, event.Receipt)
		}
		if job := event.Job; job != nil {
			entry := m.bridge.store.entries[job.ID]
			if entry == nil || !entry.Text || entry.Kind == "schema" || job.Total != entry.Bytes || job.Cursor < 0 || job.Cursor > job.Total ||
				job.Reduced < 0 || job.Reduced > len(job.Level) || len(job.Goal) > 8000 || len(job.Level)+len(job.Next) > 8192 ||
				(job.Complete && job.Cursor != job.Total) {
				return errors.New("invalid_checkpoint")
			}
			for _, id := range append(append([]string{}, job.Level...), job.Next...) {
				if m.record(id) == nil {
					return errors.New("invalid_checkpoint")
				}
			}
			if job.Result != "" && m.record(job.Result) == nil {
				return errors.New("invalid_checkpoint")
			}
			m.jobs[job.ID] = job
			m.active = job.ID
		}
	}
	if scanner.Err() != nil || m.active == "" {
		return errors.New("no_analysis_checkpoint")
	}
	if committed != len(data) {
		if err := os.Truncate(filepath.Join(m.bridge.store.directory, "task-memory.jsonl"), int64(committed)); err != nil {
			return errors.New("checkpoint_write_failed")
		}
	}
	m.bytes = committed
	// Pass and orchestration budgets start afresh for the explicitly resumed
	// attempt; the retained journal/record quotas still span the whole task.
	return nil
}

func validStoredID(id string) bool {
	if !strings.HasPrefix(id, "p") || len(id) < 2 || len(id) > 4 {
		return false
	}
	for _, c := range id[1:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
