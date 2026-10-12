// Package providers implements LLM provider support for Atlas SDK Go
package providers

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// ProviderType represents supported LLM providers
type ProviderType string

const (
	ProviderOllama       ProviderType = "ollama"
	ProviderOpenAI       ProviderType = "openai"
	ProviderAnthropic    ProviderType = "anthropic"
	ProviderAzure        ProviderType = "azure"
	ProviderBedrock      ProviderType = "bedrock"
	ProviderGoogle       ProviderType = "google"
	ProviderOpenAICompat ProviderType = "openai-compatible"
)

// ProviderResponse is the response from a provider
type ProviderResponse struct {
	Content      string     `json:"content"`
	ToolCalls    []ToolCall `json:"tool_calls,omitempty"`
	FinishReason string     `json:"finish_reason"`
	Usage        *Usage     `json:"usage,omitempty"`
}

// ToolCall represents a tool invocation
type ToolCall struct {
	ID        string                 `json:"id"`
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
}

// Usage tracks token consumption
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// StreamChunk represents a streaming response chunk
type StreamChunk struct {
	Type         string    `json:"type"`
	Content      string    `json:"content,omitempty"`
	ToolCall     *ToolCall `json:"tool_call,omitempty"`
	FinishReason string    `json:"finish_reason,omitempty"`
}

// GenerateOptions configures generation
type GenerateOptions struct {
	Messages    []Message `json:"messages"`
	Tools       []Tool    `json:"tools,omitempty"`
	Temperature float64   `json:"temperature,omitempty"`
	MaxTokens   int       `json:"max_tokens,omitempty"`
	Stop        []string  `json:"stop,omitempty"`
	Stream      bool      `json:"stream,omitempty"`
}

// Message represents a chat message
type Message struct {
	Role       string `json:"role"`
	Content    string `json:"content"`
	Name       string `json:"name,omitempty"`
	ToolCallID string `json:"tool_call_id,omitempty"`
}

// Tool represents a callable tool
type Tool struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	InputSchema map[string]interface{} `json:"input_schema"`
}

// ProviderCapabilities describes what a provider supports
type ProviderCapabilities struct {
	SupportsStreaming bool `json:"supports_streaming"`
	SupportsTools     bool `json:"supports_tools"`
	SupportsVision    bool `json:"supports_vision"`
	MaxContextLength  int  `json:"max_context_length"`
}

// Provider is the interface for LLM providers
type Provider interface {
	ID() string
	Type() ProviderType
	Model() string
	Capabilities() ProviderCapabilities
	Initialize(ctx context.Context) error
	IsAvailable(ctx context.Context) bool
	Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error)
	GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error)
	Destroy(ctx context.Context) error
}

// ProviderConfig configures a provider
type ProviderConfig struct {
	Type     ProviderType
	Model    string
	BaseURL  string
	APIKey   string
	Priority int
	Region   string // For Azure/Bedrock
}

// ProviderRegistry manages multiple providers
type ProviderRegistry struct {
	providers     map[string]Provider
	order         []string // registration order for deterministic GetPrimary fallback
	fallbackQueue []ProviderConfig
	httpClient    *http.Client
}

// NewProviderRegistry creates a new registry
func NewProviderRegistry() *ProviderRegistry {
	return &ProviderRegistry{
		providers:     make(map[string]Provider),
		order:         make([]string, 0),
		fallbackQueue: make([]ProviderConfig, 0),
		httpClient:    &http.Client{Timeout: 60 * time.Second},
	}
}

// Register adds a provider to the registry
func (r *ProviderRegistry) Register(cfg ProviderConfig) Provider {
	var provider Provider

	switch cfg.Type {
	case ProviderOpenAI:
		provider = NewOpenAIProvider(cfg.Model, cfg.APIKey, cfg.BaseURL)
	case ProviderAnthropic:
		provider = NewAnthropicProvider(cfg.Model, cfg.APIKey, cfg.BaseURL)
	case ProviderAzure:
		provider = NewAzureProvider(cfg.Model, cfg.APIKey, cfg.BaseURL, cfg.Region)
	case ProviderBedrock:
		provider = NewBedrockProvider(cfg.Model, cfg.APIKey, cfg.Region)
	case ProviderGoogle:
		provider = NewGoogleProvider(cfg.Model, cfg.APIKey, cfg.BaseURL)
	case ProviderOllama:
		provider = NewOllamaProvider(cfg.Model, cfg.APIKey, cfg.BaseURL)
	case ProviderOpenAICompat:
		provider = NewOpenAICompatibleProvider(cfg.Model, cfg.APIKey, cfg.BaseURL, string(cfg.Type))
	default:
		provider = NewOpenAICompatibleProvider(cfg.Model, cfg.APIKey, cfg.BaseURL, string(cfg.Type))
	}

	key := string(cfg.Type)
	if _, exists := r.providers[key]; !exists {
		r.order = append(r.order, key)
	}
	r.providers[key] = provider

	if cfg.Priority > 0 {
		r.fallbackQueue = append(r.fallbackQueue, cfg)
		// Sort by priority
		for i := len(r.fallbackQueue) - 1; i > 0; i-- {
			if r.fallbackQueue[i].Priority < r.fallbackQueue[i-1].Priority {
				r.fallbackQueue[i], r.fallbackQueue[i-1] = r.fallbackQueue[i-1], r.fallbackQueue[i]
			}
		}
	}

	return provider
}

// Get retrieves a provider by type
func (r *ProviderRegistry) Get(providerType ProviderType) (Provider, bool) {
	p, ok := r.providers[string(providerType)]
	return p, ok
}

// GetPrimary returns the highest priority provider. When no priorities are set,
// it falls back to the first-registered provider (deterministic insertion order)
// rather than a random map iteration.
func (r *ProviderRegistry) GetPrimary() Provider {
	if len(r.fallbackQueue) > 0 {
		if p, ok := r.providers[string(r.fallbackQueue[0].Type)]; ok {
			return p
		}
	}
	// Return first registered (deterministic via insertion order)
	for _, key := range r.order {
		if p, ok := r.providers[key]; ok {
			return p
		}
	}
	return nil
}

// GetAvailable returns the first available provider
func (r *ProviderRegistry) GetAvailable(ctx context.Context) (Provider, error) {
	primary := r.GetPrimary()
	if primary == nil {
		return nil, fmt.Errorf("no providers registered")
	}

	if primary.IsAvailable(ctx) {
		return primary, nil
	}

	// Try fallback providers
	for _, cfg := range r.fallbackQueue {
		if cfg.Type == r.fallbackQueue[0].Type {
			continue
		}
		if p, ok := r.providers[string(cfg.Type)]; ok && p.IsAvailable(ctx) {
			return p, nil
		}
	}

	return nil, fmt.Errorf("no available providers")
}

// List returns all registered providers
func (r *ProviderRegistry) List() []Provider {
	providers := make([]Provider, 0, len(r.providers))
	for _, p := range r.providers {
		providers = append(providers, p)
	}
	return providers
}

// Destroy cleans up all providers
func (r *ProviderRegistry) Destroy(ctx context.Context) error {
	var errs []error
	for _, p := range r.providers {
		if err := p.Destroy(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	r.providers = make(map[string]Provider)
	r.order = nil
	r.fallbackQueue = nil

	if len(errs) > 0 {
		return fmt.Errorf("errors destroying providers: %v", errs)
	}
	return nil
}

// BaseProvider provides common functionality
type BaseProvider struct {
	id         string
	model      string
	baseURL    string
	apiKey     string
	httpClient *http.Client
}

func (b *BaseProvider) getHeaders() map[string]string {
	h := map[string]string{
		"Content-Type": "application/json",
	}
	if b.apiKey != "" {
		h["Authorization"] = "Bearer " + b.apiKey
	}
	return h
}
