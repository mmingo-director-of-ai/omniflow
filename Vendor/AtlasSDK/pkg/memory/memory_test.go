package memory

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMemoryFilesCommandsAndStats(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	enterprise := filepath.Join(root, "enterprise.md")
	project := filepath.Join(root, "ATLAS.md")
	user := filepath.Join(root, "user.md")
	for path, content := range map[string]string{
		enterprise: "enterprise rules",
		project:    "project context",
		user:       "user preference",
	} {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	memory := NewWithPaths(enterprise, project, user)
	if err := memory.Load(); err != nil {
		t.Fatal(err)
	}
	if !memory.HasMemory() || len(memory.GetSources()) != 3 {
		t.Fatal("memory sources missing")
	}
	if all := memory.GetAll(); !strings.Contains(all, "Enterprise Memory") || !strings.Contains(all, "Project Memory") {
		t.Fatalf("unexpected hierarchy: %s", all)
	}
	if !strings.HasPrefix(memory.GetSystemPrompt(), "## Memory Context") {
		t.Fatal("system prompt missing")
	}

	memory.AddSessionMemory("temporary")
	if memory.Stats()["session"] != 1 {
		t.Fatal("session memory missing")
	}
	memory.ClearSessionMemory()
	if memory.Stats()["session"] != 0 {
		t.Fatal("session memory not cleared")
	}
	if err := memory.SaveProjectMemory("new project fact"); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(project); !strings.Contains(string(data), "new project fact") {
		t.Fatal("project memory not saved")
	}

	isMemory, content, level := ParseMemoryCommand("#project: remember this")
	if !isMemory || content != "remember this" || level != LevelProject {
		t.Fatalf("command parse mismatch: %v %q %v", isMemory, content, level)
	}
	if isMemory, _, _ := ParseMemoryCommand("## heading"); isMemory {
		t.Fatal("markdown heading should not be a memory command")
	}
	processed, message, err := memory.ProcessMemoryCommand("#user: concise")
	if err != nil || !processed || !strings.Contains(message, "user") {
		t.Fatalf("command processing failed: %v %q %v", processed, message, err)
	}
	if _, _, err := memory.ProcessMemoryCommand("#enterprise: forbidden"); err == nil {
		t.Fatal("enterprise command should be rejected")
	}
}
