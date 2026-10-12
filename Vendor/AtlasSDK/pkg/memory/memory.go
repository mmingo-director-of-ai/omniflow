// Package memory provides hierarchical memory management for Atlas SDK.
//
// Supports three levels of memory:
//   - Enterprise: ~/.claude/memory.md (shared across organization)
//   - Project: ATLAS.md (project-specific)
//   - User: ~/.atlas/memory.md (personal preferences)
//   - Session: Runtime-only temporary memories
package memory

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// MemoryLevel represents the hierarchy level of memory
type MemoryLevel int

const (
	// LevelEnterprise is the highest level, shared across organization
	LevelEnterprise MemoryLevel = iota
	// LevelProject is project-specific memory
	LevelProject
	// LevelUser is personal user memory
	LevelUser
	// LevelSession is temporary runtime memory
	LevelSession
)

// String returns the string representation of a memory level
func (l MemoryLevel) String() string {
	switch l {
	case LevelEnterprise:
		return "enterprise"
	case LevelProject:
		return "project"
	case LevelUser:
		return "user"
	case LevelSession:
		return "session"
	default:
		return "unknown"
	}
}

// MemoryEntry represents a single memory source
type MemoryEntry struct {
	Content string
	Level   MemoryLevel
	Source  string
}

// Memory represents the memory system
type Memory struct {
	Entries []MemoryEntry

	// Paths
	EnterprisePath string
	ProjectPath    string
	UserPath       string

	// Session memories (temporary, cleared on exit)
	SessionMemories []string
}

// New creates a new Memory instance with default paths
func New() *Memory {
	home, err := os.UserHomeDir()
	if err != nil {
		home = ""
	}

	return &Memory{
		Entries:         []MemoryEntry{},
		SessionMemories: []string{},
		EnterprisePath:  filepath.Join(home, ".claude", "memory.md"),
		ProjectPath:     "ATLAS.md",
		UserPath:        filepath.Join(home, ".atlas", "memory.md"),
	}
}

// NewWithPaths creates a new Memory instance with custom paths
func NewWithPaths(enterprise, project, user string) *Memory {
	return &Memory{
		Entries:         []MemoryEntry{},
		SessionMemories: []string{},
		EnterprisePath:  enterprise,
		ProjectPath:     project,
		UserPath:        user,
	}
}

// Load loads memories from all hierarchy levels
func (m *Memory) Load() error {
	// Clear existing entries
	m.Entries = []MemoryEntry{}

	// Load enterprise level (~/.claude/memory.md) - optional
	enterpriseContent, err := loadFile(m.EnterprisePath)
	if err == nil && enterpriseContent != "" {
		m.Entries = append(m.Entries, MemoryEntry{
			Content: enterpriseContent,
			Level:   LevelEnterprise,
			Source:  m.EnterprisePath,
		})
	}

	// Load project level (ATLAS.md in current project)
	projectContent, err := loadFile(m.ProjectPath)
	if err == nil && projectContent != "" {
		m.Entries = append(m.Entries, MemoryEntry{
			Content: projectContent,
			Level:   LevelProject,
			Source:  m.ProjectPath,
		})
	}

	// Load user level (~/.atlas/memory.md)
	userContent, err := loadFile(m.UserPath)
	if err == nil && userContent != "" {
		m.Entries = append(m.Entries, MemoryEntry{
			Content: userContent,
			Level:   LevelUser,
			Source:  m.UserPath,
		})
	}

	return nil
}

// LoadFromDir loads project-level memory from a specific directory
func (m *Memory) LoadFromDir(dir string) error {
	m.ProjectPath = filepath.Join(dir, "ATLAS.md")
	return m.Load()
}

// loadFile reads a file and returns its content
func loadFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("failed to read %s: %w", path, err)
	}
	return strings.TrimSpace(string(data)), nil
}

// GetAll returns all memory content combined as a system prompt
func (m *Memory) GetAll() string {
	var sb strings.Builder

	// Add enterprise level first (highest priority)
	for _, e := range m.Entries {
		if e.Level == LevelEnterprise && e.Content != "" {
			sb.WriteString("## Enterprise Memory\n\n")
			sb.WriteString(e.Content)
			sb.WriteString("\n\n")
		}
	}

	// Add project level
	for _, e := range m.Entries {
		if e.Level == LevelProject && e.Content != "" {
			sb.WriteString("## Project Memory\n\n")
			sb.WriteString(e.Content)
			sb.WriteString("\n\n")
		}
	}

	// Add user level
	for _, e := range m.Entries {
		if e.Level == LevelUser && e.Content != "" {
			sb.WriteString("## User Memory\n\n")
			sb.WriteString(e.Content)
			sb.WriteString("\n\n")
		}
	}

	// Add session memories
	if len(m.SessionMemories) > 0 {
		sb.WriteString("## Session Memory\n\n")
		for _, mem := range m.SessionMemories {
			sb.WriteString(mem)
			sb.WriteString("\n\n")
		}
	}

	return sb.String()
}

// GetSystemPrompt returns memory content formatted as a system prompt
func (m *Memory) GetSystemPrompt() string {
	content := m.GetAll()
	if content == "" {
		return ""
	}
	return "## Memory Context\n\n" + content
}

// HasMemory returns true if any memory content exists
func (m *Memory) HasMemory() bool {
	for _, e := range m.Entries {
		if e.Content != "" {
			return true
		}
	}
	return len(m.SessionMemories) > 0
}

// SaveUserMemory saves content to the user memory file (~/.atlas/memory.md)
func (m *Memory) SaveUserMemory(content string) error {
	return m.saveToFile(m.UserPath, content, LevelUser)
}

// SaveProjectMemory saves content to the project memory file (ATLAS.md)
func (m *Memory) SaveProjectMemory(content string) error {
	// Get current directory if project path is not absolute
	projectPath := m.ProjectPath
	if !filepath.IsAbs(projectPath) {
		cwd, err := os.Getwd()
		if err != nil {
			return fmt.Errorf("failed to get current directory: %w", err)
		}
		projectPath = filepath.Join(cwd, projectPath)
	}

	return m.saveToFile(projectPath, content, LevelProject)
}

// SaveEnterpriseMemory saves content to the enterprise memory file
func (m *Memory) SaveEnterpriseMemory(content string) error {
	return m.saveToFile(m.EnterprisePath, content, LevelEnterprise)
}

// saveToFile is an internal method to save content to a file
func (m *Memory) saveToFile(filePath, content string, level MemoryLevel) error {
	dir := filepath.Dir(filePath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create memory directory: %w", err)
	}

	// Append to existing content or create new
	existing, _ := loadFile(filePath)
	var newContent string
	if existing != "" {
		newContent = existing + "\n\n" + content
	} else {
		newContent = content
	}

	if err := os.WriteFile(filePath, []byte(newContent), 0644); err != nil {
		return fmt.Errorf("failed to save memory: %w", err)
	}

	// Reload memory
	m.Entries = []MemoryEntry{}
	return m.Load()
}

// AddSessionMemory adds a temporary session memory
func (m *Memory) AddSessionMemory(content string) {
	m.SessionMemories = append(m.SessionMemories, content)
}

// ClearSessionMemory clears all session memories
func (m *Memory) ClearSessionMemory() {
	m.SessionMemories = []string{}
}

// ParseMemoryCommand checks if input is a memory command (starts with #)
// and extracts the memory content
func ParseMemoryCommand(input string) (isMemory bool, content string, level MemoryLevel) {
	input = strings.TrimSpace(input)

	// Must start with # but not ## (markdown heading)
	if !strings.HasPrefix(input, "#") || strings.HasPrefix(input, "##") {
		return false, "", LevelUser
	}

	// Remove the # prefix
	content = strings.TrimSpace(input[1:])
	if content == "" {
		return false, "", LevelUser
	}

	// Check for level prefix: #user, #project, #enterprise
	lower := strings.ToLower(content)
	if strings.HasPrefix(lower, "user:") || strings.HasPrefix(lower, "user ") {
		content = strings.TrimPrefix(content, "user:")
		content = strings.TrimPrefix(content, "user ")
		return true, strings.TrimSpace(content), LevelUser
	}

	if strings.HasPrefix(lower, "project:") || strings.HasPrefix(lower, "project ") {
		content = strings.TrimPrefix(content, "project:")
		content = strings.TrimPrefix(content, "project ")
		return true, strings.TrimSpace(content), LevelProject
	}

	if strings.HasPrefix(lower, "enterprise:") || strings.HasPrefix(lower, "enterprise ") {
		content = strings.TrimPrefix(content, "enterprise:")
		content = strings.TrimPrefix(content, "enterprise ")
		return true, strings.TrimSpace(content), LevelEnterprise
	}

	// Default to user level
	return true, content, LevelUser
}

// ProcessMemoryCommand processes a memory command and saves to appropriate level
func (m *Memory) ProcessMemoryCommand(input string) (bool, string, error) {
	isMem, content, level := ParseMemoryCommand(input)
	if !isMem {
		return false, "", nil
	}

	var err error
	switch level {
	case LevelUser:
		err = m.SaveUserMemory(content)
	case LevelProject:
		err = m.SaveProjectMemory(content)
	case LevelEnterprise:
		err = fmt.Errorf("enterprise memory can only be edited manually")
	case LevelSession:
		m.AddSessionMemory(content)
	}

	if err != nil {
		return true, "", err
	}

	return true, fmt.Sprintf("Memory saved to %s level", level.String()), nil
}

// GetSources returns a list of memory sources that have content
func (m *Memory) GetSources() []string {
	var sources []string
	seen := make(map[string]bool)

	for _, e := range m.Entries {
		if e.Content != "" && !seen[e.Source] {
			sources = append(sources, e.Source)
			seen[e.Source] = true
		}
	}

	return sources
}

// Stats returns memory statistics
func (m *Memory) Stats() map[string]int {
	stats := map[string]int{
		"enterprise": 0,
		"project":    0,
		"user":       0,
		"session":    len(m.SessionMemories),
	}

	for _, e := range m.Entries {
		switch e.Level {
		case LevelEnterprise:
			if e.Content != "" {
				stats["enterprise"]++
			}
		case LevelProject:
			if e.Content != "" {
				stats["project"]++
			}
		case LevelUser:
			if e.Content != "" {
				stats["user"]++
			}
		}
	}

	return stats
}
