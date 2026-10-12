package providers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// OpenAIProvider implements OpenAI API
type OpenAIProvider struct {
	BaseProvider
}

// NewOpenAIProvider creates an OpenAI provider
func NewOpenAIProvider(model, apiKey, baseURL string) *OpenAIProvider {
	if baseURL == "" {
		baseURL = "https://api.openai.com/v1"
	}
	return &OpenAIProvider{
		BaseProvider: BaseProvider{
			id:         "openai-" + model,
			model:      model,
			baseURL:    baseURL,
			apiKey:     apiKey,
			httpClient: &http.Client{Timeout: 60 * time.Second},
		},
	}
}

// ID returns provider ID
func (p *OpenAIProvider) ID() string { return p.id }

// Type returns provider type
func (p *OpenAIProvider) Type() ProviderType { return ProviderOpenAI }

// Model returns the model
func (p *OpenAIProvider) Model() string { return p.model }

// Capabilities returns provider capabilities
func (p *OpenAIProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		SupportsStreaming: true,
		SupportsTools:     true,
		SupportsVision:    true,
		MaxContextLength:  128000,
	}
}

// Initialize sets up the provider
func (p *OpenAIProvider) Initialize(ctx context.Context) error {
	if !p.IsAvailable(ctx) {
		return fmt.Errorf("provider %s is not available", p.id)
	}
	return nil
}

// IsAvailable checks if provider is available
func (p *OpenAIProvider) IsAvailable(ctx context.Context) bool {
	if p.apiKey == "" && strings.Contains(p.baseURL, "openai.com") {
		return false
	}

	req, err := http.NewRequestWithContext(ctx, "GET", p.baseURL+"/models", nil)
	if err != nil {
		return false
	}

	for k, v := range p.getHeaders() {
		req.Header.Set(k, v)
	}

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode == http.StatusOK
}

// Generate creates a completion
func (p *OpenAIProvider) Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error) {
	url := p.baseURL + "/chat/completions"

	body := map[string]interface{}{
		"model":       p.model,
		"messages":    opts.Messages,
		"temperature": opts.Temperature,
		"max_tokens":  opts.MaxTokens,
		"stop":        opts.Stop,
	}

	if len(opts.Tools) > 0 {
		tools := make([]map[string]interface{}, len(opts.Tools))
		for i, tool := range opts.Tools {
			tools[i] = map[string]interface{}{
				"type": "function",
				"function": map[string]interface{}{
					"name":        tool.Name,
					"description": tool.Description,
					"parameters":  tool.InputSchema,
				},
			}
		}
		body["tools"] = tools
		body["tool_choice"] = "auto"
	}

	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(bodyJSON))
	if err != nil {
		return nil, err
	}

	for k, v := range p.getHeaders() {
		req.Header.Set(k, v)
	}

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("OpenAI API error: %d - %s", resp.StatusCode, string(body))
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content   string `json:"content"`
				ToolCalls []struct {
					ID       string `json:"id"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
				FinishReason string `json:"finish_reason"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
			TotalTokens      int `json:"total_tokens"`
		} `json:"usage"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	if len(result.Choices) == 0 {
		return nil, fmt.Errorf("no choices returned")
	}

	choice := result.Choices[0]

	var toolCalls []ToolCall
	for _, tc := range choice.Message.ToolCalls {
		var args map[string]interface{}
		json.Unmarshal([]byte(tc.Function.Arguments), &args)
		toolCalls = append(toolCalls, ToolCall{
			ID:        tc.ID,
			Name:      tc.Function.Name,
			Arguments: args,
		})
	}

	return &ProviderResponse{
		Content:      choice.Message.Content,
		ToolCalls:    toolCalls,
		FinishReason: choice.FinishReason,
		Usage: &Usage{
			PromptTokens:     result.Usage.PromptTokens,
			CompletionTokens: result.Usage.CompletionTokens,
			TotalTokens:      result.Usage.TotalTokens,
		},
	}, nil
}

// GenerateStream streams a completion
func (p *OpenAIProvider) GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	// Simplified implementation - full SSE streaming would require more code
	resp, err := p.Generate(ctx, opts)
	if err != nil {
		return nil, err
	}

	onChunk(StreamChunk{Type: "content", Content: resp.Content})
	onChunk(StreamChunk{Type: "finish", FinishReason: resp.FinishReason})

	return resp, nil
}

// Destroy cleans up resources
func (p *OpenAIProvider) Destroy(ctx context.Context) error {
	return nil
}
