package providers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// AnthropicProvider implements Anthropic API
type AnthropicProvider struct {
	BaseProvider
}

// NewAnthropicProvider creates an Anthropic provider
func NewAnthropicProvider(model, apiKey, baseURL string) *AnthropicProvider {
	if baseURL == "" {
		baseURL = "https://api.anthropic.com/v1"
	}
	return &AnthropicProvider{
		BaseProvider: BaseProvider{
			id:         "anthropic-" + model,
			model:      model,
			baseURL:    baseURL,
			apiKey:     apiKey,
			httpClient: &http.Client{Timeout: 60 * time.Second},
		},
	}
}

// ID returns provider ID
func (p *AnthropicProvider) ID() string { return p.id }

// Type returns provider type
func (p *AnthropicProvider) Type() ProviderType { return ProviderAnthropic }

// Model returns the model
func (p *AnthropicProvider) Model() string { return p.model }

// Capabilities returns provider capabilities
func (p *AnthropicProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		SupportsStreaming: true,
		SupportsTools:     true,
		SupportsVision:    true,
		MaxContextLength:  200000,
	}
}

// Initialize sets up the provider
func (p *AnthropicProvider) Initialize(ctx context.Context) error {
	if !p.IsAvailable(ctx) {
		return fmt.Errorf("provider %s is not available", p.id)
	}
	return nil
}

// IsAvailable checks if provider is available
func (p *AnthropicProvider) IsAvailable(ctx context.Context) bool {
	if p.apiKey == "" {
		return false
	}

	req, err := http.NewRequestWithContext(ctx, "GET", p.baseURL+"/models", nil)
	if err != nil {
		return false
	}

	req.Header.Set("x-api-key", p.apiKey)
	req.Header.Set("anthropic-version", "2023-06-01")

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode == http.StatusOK
}

// Generate creates a completion
func (p *AnthropicProvider) Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error) {
	url := p.baseURL + "/messages"

	// Separate system message
	var systemMsg string
	messages := make([]map[string]interface{}, 0, len(opts.Messages))
	for _, m := range opts.Messages {
		if m.Role == "system" {
			systemMsg = m.Content
			continue
		}
		role := m.Role
		if role == "tool" {
			role = "user" // Anthropic uses user role for tool results
		}
		messages = append(messages, map[string]interface{}{
			"role":    role,
			"content": m.Content,
		})
	}

	body := map[string]interface{}{
		"model":          p.model,
		"messages":       messages,
		"max_tokens":     opts.MaxTokens,
		"temperature":    opts.Temperature,
		"stop_sequences": opts.Stop,
	}

	if systemMsg != "" {
		body["system"] = systemMsg
	}

	if len(opts.Tools) > 0 {
		tools := make([]map[string]interface{}, len(opts.Tools))
		for i, tool := range opts.Tools {
			tools[i] = map[string]interface{}{
				"name":         tool.Name,
				"description":  tool.Description,
				"input_schema": tool.InputSchema,
			}
		}
		body["tools"] = tools
	}

	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(bodyJSON))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", p.apiKey)
	req.Header.Set("anthropic-version", "2023-06-01")

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("Anthropic API error: %d - %s", resp.StatusCode, string(body))
	}

	var result struct {
		Content    []ContentBlock `json:"content"`
		StopReason string         `json:"stop_reason"`
		Usage      Usage          `json:"usage"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	var content string
	var toolCalls []ToolCall

	for _, block := range result.Content {
		switch block.Type {
		case "text":
			content += block.Text
		case "tool_use":
			toolCalls = append(toolCalls, ToolCall{
				ID:        block.ID,
				Name:      block.Name,
				Arguments: block.Input,
			})
		}
	}

	return &ProviderResponse{
		Content:      content,
		ToolCalls:    toolCalls,
		FinishReason: result.StopReason,
		Usage: &Usage{
			PromptTokens:     result.Usage.PromptTokens,
			CompletionTokens: result.Usage.CompletionTokens,
			TotalTokens:      result.Usage.TotalTokens,
		},
	}, nil
}

// ContentBlock represents Anthropic content block
type ContentBlock struct {
	Type  string                 `json:"type"`
	Text  string                 `json:"text,omitempty"`
	ID    string                 `json:"id,omitempty"`
	Name  string                 `json:"name,omitempty"`
	Input map[string]interface{} `json:"input,omitempty"`
}

// GenerateStream streams a completion
func (p *AnthropicProvider) GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	// Simplified - full streaming implementation needed
	resp, err := p.Generate(ctx, opts)
	if err != nil {
		return nil, err
	}

	onChunk(StreamChunk{Type: "content", Content: resp.Content})
	onChunk(StreamChunk{Type: "finish", FinishReason: resp.FinishReason})

	return resp, nil
}

// Destroy cleans up resources
func (p *AnthropicProvider) Destroy(ctx context.Context) error {
	return nil
}
