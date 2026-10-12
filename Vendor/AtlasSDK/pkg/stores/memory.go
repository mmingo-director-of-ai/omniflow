package stores

import "context"

// MemoryLevel matches the TypeScript SDK MemoryLevel enum.
type MemoryLevel string

const (
	MemoryLevelEnterprise MemoryLevel = "enterprise"
	MemoryLevelProject    MemoryLevel = "project"
	MemoryLevelUser       MemoryLevel = "user"
	MemoryLevelSession    MemoryLevel = "session"
)

// StoredMemoryEntry is a persistent memory record.
type StoredMemoryEntry struct {
	ID        string                 `json:"id,omitempty"`
	Content   string                 `json:"content"`
	Level     MemoryLevel            `json:"level"`
	Source    string                 `json:"source"`
	Tags      []string               `json:"tags,omitempty"`
	Embedding []float64              `json:"embedding,omitempty"`
	CreatedAt int64                  `json:"createdAt,omitempty"`
	UpdatedAt int64                  `json:"updatedAt,omitempty"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
}

// MemorySearchOptions configures memory search.
type MemorySearchOptions struct {
	Level          MemoryLevel
	Limit          int
	Threshold      float64
	Tags           []string
	TenantID       string
	Namespace      string
	IncludeExpired bool
	Now            int64
}

// MemorySearchResult pairs an entry with a relevance score.
type MemorySearchResult struct {
	Entry StoredMemoryEntry `json:"entry"`
	Score float64           `json:"score"`
}

// MemoryStore manages persistent knowledge across sessions.
type MemoryStore interface {
	Init(ctx context.Context) error
	Close(ctx context.Context) error
	Save(ctx context.Context, entry StoredMemoryEntry) (string, error)
	Get(ctx context.Context, id string) (*StoredMemoryEntry, error)
	Update(ctx context.Context, id string, entry StoredMemoryEntry) error
	Delete(ctx context.Context, id string) error
	GetByLevel(ctx context.Context, level MemoryLevel) ([]StoredMemoryEntry, error)
	Search(ctx context.Context, query string, opts *MemorySearchOptions) ([]MemorySearchResult, error)
	LoadAll(ctx context.Context) ([]StoredMemoryEntry, error)
	GetSystemPrompt(ctx context.Context) (string, error)
}

// AtomicMemoryStore is the optional capability required by mutable
// conversation branch heads. UpdatedAt is the compare-and-swap token.
type AtomicMemoryStore interface {
	MemoryStore
	CompareAndSwap(ctx context.Context, id string, expectedUpdatedAt int64, entry StoredMemoryEntry) (bool, error)
}
