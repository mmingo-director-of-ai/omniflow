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

// GoogleProvider implements Google Gemini API
type GoogleProvider struct {
	BaseProvider
}

// NewGoogleProvider creates a Google provider
func NewGoogleProvider(model, apiKey, baseURL string) *GoogleProvider {
	if baseURL == "" {
		baseURL = "https://generativelanguage.googleapis.com/v1beta"
	}
	return &GoogleProvider{
		BaseProvider: BaseProvider{
			id:         "google-" + model,
			model:      model,
			baseURL:    baseURL,
			apiKey:     apiKey,
			httpClient: &http.Client{Timeout: 60 * time.Second},
		},
	}
}

// ID returns provider ID
func (p *GoogleProvider) ID() string { return p.id }

// Type returns provider type
func (p *GoogleProvider) Type() ProviderType { return ProviderGoogle }

// Model returns the model
func (p *GoogleProvider) Model() string { return p.model }

// Capabilities returns provider capabilities
func (p *GoogleProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		SupportsStreaming: true,
		SupportsTools:     true,
		SupportsVision:    true,
		MaxContextLength:  1048576, // 1M tokens for Gemini
	}
}

// Initialize sets up the provider
func (p *GoogleProvider) Initialize(ctx context.Context) error {
	if !p.IsAvailable(ctx) {
		return fmt.Errorf("provider %s is not available", p.id)
	}
	return nil
}

// IsAvailable checks if provider is available
func (p *GoogleProvider) IsAvailable(ctx context.Context) bool {
	if p.apiKey == "" {
		return false
	}
	// Quick check
	url := fmt.Sprintf("%s/models?key=%s", p.baseURL, p.apiKey)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return false
	}
	resp, err := p.httpClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// Generate creates a completion
func (p *GoogleProvider) Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error) {
	url := fmt.Sprintf("%s/models/%s:generateContent?key=%s", p.baseURL, p.model, p.apiKey)

	// Convert messages to Gemini format
	contents := make([]map[string]interface{}, 0, len(opts.Messages))
	for _, m := range opts.Messages {
		if m.Role == "system" {
			// Gemini handles system differently
			continue
		}
		role := "user"
		if m.Role == "assistant" || m.Role == "model" {
			role = "model"
		}
		contents = append(contents, map[string]interface{}{
			"role": role,
			"parts": []map[string]string{
				{"text": m.Content},
			},
		})
	}

	body := map[string]interface{}{
		"contents": contents,
		"generationConfig": map[string]interface{}{
			"temperature":     opts.Temperature,
			"maxOutputTokens": opts.MaxTokens,
			"stopSequences":   opts.Stop,
		},
	}

	if len(opts.Tools) > 0 {
		tools := make([]map[string]interface{}, len(opts.Tools))
		for i, tool := range opts.Tools {
			tools[i] = map[string]interface{}{
				"functionDeclarations": []map[string]interface{}{
					{
						"name":        tool.Name,
						"description": tool.Description,
						"parameters":  tool.InputSchema,
					},
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

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("Google API error: %d - %s", resp.StatusCode, string(body))
	}

	var result struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text         string `json:"text"`
					FunctionCall *struct {
						Name string                 `json:"name"`
						Args map[string]interface{} `json:"args"`
					} `json:"functionCall"`
				} `json:"parts"`
			} `json:"content"`
			FinishReason string `json:"finishReason"`
		} `json:"candidates"`
		UsageMetadata struct {
			PromptTokenCount     int `json:"promptTokenCount"`
			CandidatesTokenCount int `json:"candidatesTokenCount"`
			TotalTokenCount      int `json:"totalTokenCount"`
		} `json:"usageMetadata"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	if len(result.Candidates) == 0 {
		return nil, fmt.Errorf("no candidates returned")
	}

	candidate := result.Candidates[0]

	var content string
	var toolCalls []ToolCall

	for _, part := range candidate.Content.Parts {
		if part.Text != "" {
			content += part.Text
		}
		if part.FunctionCall != nil {
			toolCalls = append(toolCalls, ToolCall{
				Name:      part.FunctionCall.Name,
				Arguments: part.FunctionCall.Args,
			})
		}
	}

	return &ProviderResponse{
		Content:      content,
		ToolCalls:    toolCalls,
		FinishReason: candidate.FinishReason,
		Usage: &Usage{
			PromptTokens:     result.UsageMetadata.PromptTokenCount,
			CompletionTokens: result.UsageMetadata.CandidatesTokenCount,
			TotalTokens:      result.UsageMetadata.TotalTokenCount,
		},
	}, nil
}

// GenerateStream streams a completion
func (p *GoogleProvider) GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	return p.Generate(ctx, opts)
}

// Destroy cleans up resources
func (p *GoogleProvider) Destroy(ctx context.Context) error {
	return nil
}
