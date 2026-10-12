package talents

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoaderLifecycle(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	validDir := filepath.Join(root, "valid")
	invalidDir := filepath.Join(root, "invalid")
	if err := os.MkdirAll(validDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(invalidDir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := "---\nname: investigate\ndescription: Investigate alerts\ntools:\n  - search\n---\n# Instructions\nDo the work.\n"
	if err := os.WriteFile(filepath.Join(validDir, "TALENT.md"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(invalidDir, "TALENT.md"), []byte("invalid"), 0o644); err != nil {
		t.Fatal(err)
	}

	loader := NewLoader()
	talent, err := loader.LoadFromDirectory(validDir)
	if err != nil || talent.Metadata.Name != "investigate" || talent.GetSystemPrompt() == "" {
		t.Fatalf("load failed: %#v, %v", talent, err)
	}
	if _, err := loader.LoadFromDirectory(filepath.Join(root, "missing")); err == nil {
		t.Fatal("missing talent should fail")
	}
	all, err := loader.LoadAll(root)
	if err != nil || len(all) != 1 {
		t.Fatalf("load all failed: %#v, %v", all, err)
	}
	if got, ok := loader.Get("investigate"); !ok || got.Metadata.Name != talent.Metadata.Name {
		t.Fatal("get failed")
	}
	if len(loader.List()) != 1 || len(loader.ListNames()) != 1 {
		t.Fatal("list failed")
	}
}
