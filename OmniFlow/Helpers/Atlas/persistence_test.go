package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDurableAnalysisRestoresCommittedCursorAndEvidence(t *testing.T) {
	attempt := 0
	m := memoryFixture(t, func(request analysisRequest) frame {
		attempt++
		if attempt == 2 {
			return frame{AnalysisError: "interrupted"}
		}
		if request.Phase == "merge" {
			var texts []string
			for _, record := range request.Records {
				texts = append(texts, record.Text)
			}
			return frame{AnalysisResult: &analysisReply{Text: strings.Join(texts, " "), Records: len(request.Records)}}
		}
		text := utf8Prefix(request.Text, 4000)
		quote := utf8Prefix(text, 80)
		return frame{AnalysisResult: &analysisReply{Text: quote, Quotes: []string{quote}, Bytes: len(text)}}
	})
	s := m.bridge.store
	t.Cleanup(func() { os.RemoveAll(s.directory) })
	s.question = "Read the complete archive"
	if err := s.enablePersistence(false); err != nil {
		t.Fatal(err)
	}
	entry, err := s.put("fixture", []byte("First: staging only.\n"+strings.Repeat("café 紅熊猫\n", 2000)+"Final: production NOT approved."), true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.analyze(context.Background(), entry.ID, ""); err == nil {
		t.Fatal("expected interrupted generation")
	}
	cursor := m.jobs[entry.ID].Cursor
	if cursor < 3996 || cursor > 4000 || len(m.records) != 1 {
		t.Fatal("incorrect committed prefix")
	}
	s.close()
	journal := filepath.Join(s.directory, "task-memory.jsonl")
	f, err := os.OpenFile(journal, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(`{"record":`)
	f.Close() // simulate process death during the next append
	reopened, err := newPayloadStore(s.directory)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.close()
	reopened.question = s.question
	if err := reopened.enablePersistence(true); err != nil {
		t.Fatal(err)
	}
	m.bridge.store = reopened
	restored := newTaskMemory(m.bridge)
	m.bridge.memory = restored
	if err := restored.restore(); err != nil {
		t.Fatal(err)
	}
	if restored.jobs[entry.ID].Cursor != cursor || len(restored.records) != 1 || restored.active != entry.ID {
		t.Fatal("committed progress was not restored")
	}
	for !restored.jobs[entry.ID].Complete {
		if _, err := restored.analyze(context.Background(), entry.ID, ""); err != nil {
			t.Fatal(err)
		}
	}
	if restored.jobs[entry.ID].Cursor != entry.Bytes {
		t.Fatal("resume did not finish original evidence")
	}
	data, _ := os.ReadFile(journal)
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if !json.Valid([]byte(line)) {
			t.Fatal("partial append was not recovered")
		}
	}
	if _, err := os.Stat(filepath.Join(s.directory, entry.ID+".gz")); err != nil {
		t.Fatal("durable source was deleted")
	}
}

func TestFailedResumeNeverDeletesOrOverwritesWorkspace(t *testing.T) {
	s, err := newPayloadStore("")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(s.directory)
	s.question = "Original goal"
	if err := s.enablePersistence(false); err != nil {
		t.Fatal(err)
	}
	entry, _ := s.put("fixture", []byte("Important original evidence"), true)
	other, _ := newPayloadStore(s.directory)
	other.question = s.question
	if err := other.enablePersistence(true); err == nil {
		t.Fatal("a second process acquired a live workspace")
	}
	other.close()
	if _, _, err := s.data(entry.ID); err != nil {
		t.Fatal("failed lock destroyed the original data")
	}
	s.close()
	other, _ = newPayloadStore(s.directory)
	other.question = "Different goal"
	if err := other.enablePersistence(true); err == nil {
		t.Fatal("resume silently changed the user's goal")
	}
	other.close()
	if _, err := os.Stat(filepath.Join(s.directory, entry.ID+".gz")); err != nil {
		t.Fatal("failed validation destroyed saved evidence")
	}
	other, _ = newPayloadStore(s.directory)
	other.question = s.question
	if err := other.enablePersistence(false); err == nil {
		t.Fatal("new run overwrote an existing checkpoint")
	}
	other.close()
}

func TestRestoreRejectsDamagedOrRedirectedEvidence(t *testing.T) {
	for _, redirected := range []bool{false, true} {
		s, _ := newPayloadStore("")
		s.question = "Evidence"
		if err := s.enablePersistence(false); err != nil {
			t.Fatal(err)
		}
		entry, _ := s.put("fixture", []byte("Original evidence"), true)
		s.close()
		path := filepath.Join(s.directory, entry.ID+".gz")
		if redirected {
			os.Rename(path, path+".original")
			if err := os.Symlink(path+".original", path); err != nil {
				t.Fatal(err)
			}
		} else {
			os.WriteFile(path, []byte("damaged gzip"), 0600)
		}
		other, _ := newPayloadStore(s.directory)
		other.question = s.question
		if err := other.enablePersistence(true); err == nil {
			t.Fatal("invalid evidence was trusted on resume")
		}
		other.close()
		os.RemoveAll(s.directory)
	}
}
