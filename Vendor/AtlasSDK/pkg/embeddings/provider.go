// Package embeddings provides embedding provider abstraction for semantic search.
//
// Supports pluggable embedding providers (Ollama, OpenAI, etc.)
// for converting text into vector embeddings for similarity search.
package embeddings

import "context"

// EmbeddingVector represents a vector embedding of text.
type EmbeddingVector struct {
	// Values is the vector (typically 768 or 1536 dimensions).
	Values []float64
	// Model that generated this embedding.
	Model string
	// TokenCount if available.
	TokenCount int
}

// EmbeddingResult contains an embedding and its metadata.
type EmbeddingResult struct {
	Embedding EmbeddingVector
	Text      string
	Timestamp int64
}

// ProviderConfig holds configuration for an embedding provider.
type ProviderConfig struct {
	// Provider identifier (ollama, openai, etc.).
	Provider string
	// Model to use for embeddings.
	Model string
	// BaseURL for the provider API.
	BaseURL string
	// APIKey if required.
	APIKey string
	// BatchSize for bulk embedding.
	BatchSize int
	// Timeout in milliseconds.
	Timeout int
}

// Provider defines the interface for embedding text into vectors.
type Provider interface {
	// Name returns the provider name.
	Name() string

	// DefaultModel returns the default model for embeddings.
	DefaultModel() string

	// Embed generates an embedding for a single text.
	Embed(ctx context.Context, text string) (*EmbeddingVector, error)

	// EmbedBatch generates embeddings for multiple texts.
	EmbedBatch(ctx context.Context, texts []string) ([]*EmbeddingVector, error)

	// IsAvailable checks if the provider is available.
	IsAvailable(ctx context.Context) bool
}

// SearchResult contains a search match.
type SearchResult struct {
	// ID is the memory entry identifier.
	ID string
	// Level is the memory level (enterprise, project, user, session).
	Level string
	// Source is the file path.
	Source string
	// Text that matched.
	Text string
	// Score is the similarity score (0-1).
	Score float64
	// Snippet is a highlighted snippet if available.
	Snippet string
}

// SearchOptions configures search behavior.
type SearchOptions struct {
	// Limit is the maximum number of results.
	Limit int
	// Threshold is the minimum similarity score (0-1).
	Threshold float64
	// Level filters by memory level.
	Level string
	// IncludeSnippet includes snippet in results.
	IncludeSnippet bool
}

// MemoryEmbedding stores an embedding with its metadata.
type MemoryEmbedding struct {
	ID        string
	Level     string
	Source    string
	Text      string
	Embedding []float64
	Timestamp int64
}

// MemoryLevel constants.
const (
	LevelEnterprise = "enterprise"
	LevelProject    = "project"
	LevelUser       = "user"
	LevelSession    = "session"
)
