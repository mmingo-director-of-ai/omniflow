// Package embeddings provides embedding provider abstraction for semantic search.
package embeddings

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// OllamaProvider implements embedding using local Ollama server.
type OllamaProvider struct {
	baseURL string
	model   string
	timeout time.Duration
}

// ollamaEmbeddingRequest is the request body for Ollama embeddings.
type ollamaEmbeddingRequest struct {
	Model  string `json:"model"`
	Prompt string `json:"prompt"`
}

// ollamaEmbeddingResponse is the response from Ollama embeddings.
type ollamaEmbeddingResponse struct {
	Embedding []float64 `json:"embedding"`
}

// NewOllamaProvider creates a new Ollama embedding provider.
func NewOllamaProvider(config ProviderConfig) *OllamaProvider {
	baseURL := config.BaseURL
	if baseURL == "" {
		baseURL = "http://localhost:11434"
	}

	model := config.Model
	if model == "" {
		model = "nomic-embed-text"
	}

	timeout := time.Duration(config.Timeout) * time.Millisecond
	if timeout == 0 {
		timeout = 30 * time.Second
	}

	return &OllamaProvider{
		baseURL: baseURL,
		model:   model,
		timeout: timeout,
	}
}

// Name returns the provider name.
func (p *OllamaProvider) Name() string {
	return "ollama"
}

// DefaultModel returns the default model.
func (p *OllamaProvider) DefaultModel() string {
	return "nomic-embed-text"
}

// Embed generates an embedding for a single text.
func (p *OllamaProvider) Embed(ctx context.Context, text string) (*EmbeddingVector, error) {
	req := ollamaEmbeddingRequest{
		Model:  p.model,
		Prompt: text,
	}

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", p.baseURL+"/api/embeddings", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: p.timeout}
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("ollama embedding failed: %s", string(respBody))
	}

	var result ollamaEmbeddingResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &EmbeddingVector{
		Values: result.Embedding,
		Model:  p.model,
	}, nil
}

// EmbedBatch generates embeddings for multiple texts.
func (p *OllamaProvider) EmbedBatch(ctx context.Context, texts []string) ([]*EmbeddingVector, error) {
	results := make([]*EmbeddingVector, len(texts))

	// Ollama doesn't have a batch endpoint, so we parallelize individual calls
	// but limit concurrency to avoid overwhelming the server
	sem := make(chan struct{}, 5) // Max 5 concurrent requests
	errChan := make(chan error, len(texts))

	for i, text := range texts {
		go func(idx int, txt string) {
			sem <- struct{}{}
			defer func() { <-sem }()

			emb, err := p.Embed(ctx, txt)
			if err != nil {
				errChan <- err
				return
			}
			results[idx] = emb
			errChan <- nil
		}(i, text)
	}

	// Wait for all requests to complete
	for range texts {
		if err := <-errChan; err != nil {
			return nil, err
		}
	}

	return results, nil
}

// IsAvailable checks if Ollama is running.
func (p *OllamaProvider) IsAvailable(ctx context.Context) bool {
	client := &http.Client{Timeout: 2 * time.Second}
	req, err := http.NewRequestWithContext(ctx, "GET", p.baseURL+"/api/version", nil)
	if err != nil {
		return false
	}

	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode == http.StatusOK
}

// SetModel changes the model used for embeddings.
func (p *OllamaProvider) SetModel(model string) {
	p.model = model
}

// SetBaseURL changes the Ollama server URL.
func (p *OllamaProvider) SetBaseURL(url string) {
	p.baseURL = url
}
