// Package embeddings provides embedding provider abstraction for semantic search.
package embeddings

import (
	"math"
)

// MemoryVectorStore stores embeddings with memory references.
type MemoryVectorStore struct {
	embeddings map[string]*MemoryEmbedding
}

// NewMemoryVectorStore creates a new in-memory vector store.
func NewMemoryVectorStore() *MemoryVectorStore {
	return &MemoryVectorStore{
		embeddings: make(map[string]*MemoryEmbedding),
	}
}

// Add stores an embedding in the vector store.
func (s *MemoryVectorStore) Add(id, level, source, text string, embedding *EmbeddingVector) {
	s.embeddings[id] = &MemoryEmbedding{
		ID:        id,
		Level:     level,
		Source:    source,
		Text:      text,
		Embedding: embedding.Values,
		Timestamp: 0, // Will be set by caller if needed
	}
}

// Remove deletes an embedding from the store.
func (s *MemoryVectorStore) Remove(id string) {
	delete(s.embeddings, id)
}

// GetByLevel returns all embeddings for a level.
func (s *MemoryVectorStore) GetByLevel(level string) []*MemoryEmbedding {
	var result []*MemoryEmbedding
	for _, e := range s.embeddings {
		if e.Level == level {
			result = append(result, e)
		}
	}
	return result
}

// GetAll returns all embeddings.
func (s *MemoryVectorStore) GetAll() []*MemoryEmbedding {
	result := make([]*MemoryEmbedding, 0, len(s.embeddings))
	for _, e := range s.embeddings {
		result = append(result, e)
	}
	return result
}

// Clear removes all embeddings.
func (s *MemoryVectorStore) Clear() {
	s.embeddings = make(map[string]*MemoryEmbedding)
}

// Search finds similar embeddings using cosine similarity.
func (s *MemoryVectorStore) Search(query []float64, opts SearchOptions) []*SearchResult {
	limit := opts.Limit
	if limit == 0 {
		limit = 10
	}
	threshold := opts.Threshold
	if threshold == 0 {
		threshold = 0.5
	}

	var candidates []*MemoryEmbedding
	if opts.Level != "" {
		candidates = s.GetByLevel(opts.Level)
	} else {
		candidates = s.GetAll()
	}

	// Calculate similarity for each candidate
	results := make([]*SearchResult, 0, len(candidates))
	for _, e := range candidates {
		score := cosineSimilarity(query, e.Embedding)
		if score >= threshold {
			results = append(results, &SearchResult{
				ID:      e.ID,
				Level:   e.Level,
				Source:  e.Source,
				Text:    e.Text,
				Score:   score,
				Snippet: truncateText(e.Text, 200),
			})
		}
	}

	// Sort by score descending
	sortResultsByScore(results)

	// Return top results
	if len(results) > limit {
		results = results[:limit]
	}

	return results
}

// Stats returns statistics about the store.
func (s *MemoryVectorStore) Stats() (count int, byLevel map[string]int) {
	byLevel = make(map[string]int)
	for _, e := range s.embeddings {
		byLevel[e.Level]++
	}
	return len(s.embeddings), byLevel
}

// cosineSimilarity calculates the cosine similarity between two vectors.
func cosineSimilarity(a, b []float64) float64 {
	if len(a) != len(b) {
		return 0
	}

	var dotProduct, normA, normB float64
	for i := range a {
		dotProduct += a[i] * b[i]
		normA += a[i] * a[i]
		normB += b[i] * b[i]
	}

	denom := math.Sqrt(normA) * math.Sqrt(normB)
	if denom == 0 {
		return 0
	}
	return dotProduct / denom
}

// truncateText truncates text for snippet.
func truncateText(text string, maxLen int) string {
	if len(text) <= maxLen {
		return text
	}
	return text[:maxLen] + "..."
}

// sortResultsByScore sorts results by score descending.
func sortResultsByScore(results []*SearchResult) {
	for i := 0; i < len(results)-1; i++ {
		for j := i + 1; j < len(results); j++ {
			if results[j].Score > results[i].Score {
				results[i], results[j] = results[j], results[i]
			}
		}
	}
}
