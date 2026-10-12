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

// AzureProvider implements Azure OpenAI API
type AzureProvider struct {
	BaseProvider
	region string
}

// NewAzureProvider creates an Azure provider
func NewAzureProvider(model, apiKey, baseURL, region string) *AzureProvider {
	if baseURL == "" {
		baseURL = fmt.Sprintf("https://%s.openai.azure.com/openai/deployments/%s", region, model)
	}
	return &AzureProvider{
		BaseProvider: BaseProvider{
			id:         "azure-" + model,
			model:      model,
			baseURL:    baseURL,
			apiKey:     apiKey,
			httpClient: &http.Client{Timeout: 60 * time.Second},
		},
		region: region,
	}
}

// ID returns provider ID
func (p *AzureProvider) ID() string { return p.id }

// Type returns provider type
func (p *AzureProvider) Type() ProviderType { return ProviderAzure }

// Model returns the model
func (p *AzureProvider) Model() string { return p.model }

// Capabilities returns provider capabilities
func (p *AzureProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		SupportsStreaming: true,
		SupportsTools:     true,
		SupportsVision:    true,
		MaxContextLength:  128000,
	}
}

// Initialize sets up the provider
func (p *AzureProvider) Initialize(ctx context.Context) error {
	if !p.IsAvailable(ctx) {
		return fmt.Errorf("provider %s is not available", p.id)
	}
	return nil
}

// IsAvailable checks if provider is available
func (p *AzureProvider) IsAvailable(ctx context.Context) bool {
	if p.apiKey == "" || p.region == "" {
		return false
	}
	// Azure specific check
	req, err := http.NewRequestWithContext(ctx, "GET", p.baseURL, nil)
	if err != nil {
		return false
	}
	req.Header.Set("api-key", p.apiKey)
	resp, err := p.httpClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	// Any response means it's available (even 404)
	return resp.StatusCode != 0
}

// Generate creates a completion
func (p *AzureProvider) Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error) {
	url := p.baseURL + "/chat/completions?api-version=2024-02-01"

	body := map[string]interface{}{
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
	req.Header.Set("api-key", p.apiKey)

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("Azure API error: %d - %s", resp.StatusCode, string(body))
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content      string     `json:"content"`
				ToolCalls    []ToolCall `json:"tool_calls"`
				FinishReason string     `json:"finish_reason"`
			} `json:"message"`
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

	return &ProviderResponse{
		Content:      choice.Message.Content,
		ToolCalls:    choice.Message.ToolCalls,
		FinishReason: choice.Message.FinishReason,
		Usage: &Usage{
			PromptTokens:     result.Usage.PromptTokens,
			CompletionTokens: result.Usage.CompletionTokens,
			TotalTokens:      result.Usage.TotalTokens,
		},
	}, nil
}

// GenerateStream streams a completion
func (p *AzureProvider) GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	return p.Generate(ctx, opts)
}

// Destroy cleans up resources
func (p *AzureProvider) Destroy(ctx context.Context) error {
	return nil
}
