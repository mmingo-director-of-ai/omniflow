// Package talents provides talent (skill) loading and management
package talents

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Metadata represents talent metadata from TALENT.md frontmatter
type Metadata struct {
	Name        string     `yaml:"name"`
	Version     string     `yaml:"version"`
	Description string     `yaml:"description"`
	Author      string     `yaml:"author"`
	Tools       []string   `yaml:"tools"`
	MCP         *MCPConfig `yaml:"mcp,omitempty"`
}

// MCPConfig holds MCP server configuration for a talent
type MCPConfig struct {
	Name      string             `yaml:"name"`
	Transport MCPTransportConfig `yaml:"transport"`
}

// MCPTransportConfig holds transport-specific configuration
type MCPTransportConfig struct {
	Type    string            `yaml:"type"` // "stdio", "http", "sse"
	Command string            `yaml:"command,omitempty"`
	Args    []string          `yaml:"args,omitempty"`
	Env     map[string]string `yaml:"env,omitempty"`
	URL     string            `yaml:"url,omitempty"`
	Headers map[string]string `yaml:"headers,omitempty"`
}

// Talent represents a loaded talent
type Talent struct {
	Metadata Metadata
	Content  string // Full TALENT.md content
	Path     string // Directory path
}

// Loader handles talent loading
type Loader struct {
	talents map[string]*Talent
}

// NewLoader creates a new talent loader
func NewLoader() *Loader {
	return &Loader{
		talents: make(map[string]*Talent),
	}
}

// LoadFromDirectory loads a talent from a directory
func (l *Loader) LoadFromDirectory(path string) (*Talent, error) {
	talentFile := filepath.Join(path, "TALENT.md")
	content, err := os.ReadFile(talentFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read TALENT.md: %w", err)
	}

	talent, err := l.parseTalent(string(content))
	if err != nil {
		return nil, fmt.Errorf("failed to parse TALENT.md: %w", err)
	}

	talent.Path = path
	l.talents[talent.Metadata.Name] = talent

	return talent, nil
}

// LoadAll loads all talents from a directory
func (l *Loader) LoadAll(dir string) ([]*Talent, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to read directory: %w", err)
	}

	var talents []*Talent
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		talentPath := filepath.Join(dir, entry.Name())
		talentFile := filepath.Join(talentPath, "TALENT.md")

		if _, err := os.Stat(talentFile); err != nil {
			continue // Not a talent directory
		}

		talent, err := l.LoadFromDirectory(talentPath)
		if err != nil {
			continue // Skip invalid talents
		}

		talents = append(talents, talent)
	}

	return talents, nil
}

// Get retrieves a loaded talent by name
func (l *Loader) Get(name string) (*Talent, bool) {
	t, ok := l.talents[name]
	return t, ok
}

// List returns all loaded talents
func (l *Loader) List() []*Talent {
	list := make([]*Talent, 0, len(l.talents))
	for _, t := range l.talents {
		list = append(list, t)
	}
	return list
}

// ListNames returns names of all loaded talents
func (l *Loader) ListNames() []string {
	names := make([]string, 0, len(l.talents))
	for name := range l.talents {
		names = append(names, name)
	}
	return names
}

func (l *Loader) parseTalent(content string) (*Talent, error) {
	// Parse YAML frontmatter
	if !strings.HasPrefix(content, "---") {
		return nil, fmt.Errorf("TALENT.md must start with YAML frontmatter")
	}

	parts := strings.SplitN(content[3:], "---", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid YAML frontmatter format")
	}

	var metadata Metadata
	if err := yaml.Unmarshal([]byte(parts[0]), &metadata); err != nil {
		return nil, fmt.Errorf("failed to parse YAML frontmatter: %w", err)
	}

	return &Talent{
		Metadata: metadata,
		Content:  strings.TrimSpace(parts[1]),
	}, nil
}

// GetSystemPrompt returns the system prompt for a talent
func (t *Talent) GetSystemPrompt() string {
	return t.Content
}
