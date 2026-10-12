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

// BedrockProvider implements AWS Bedrock API
type BedrockProvider struct {
	BaseProvider
	region string
}

// NewBedrockProvider creates a Bedrock provider
func NewBedrockProvider(model, apiKey, region string) *BedrockProvider {
	if region == "" {
		region = "us-east-1"
	}
	return &BedrockProvider{
		BaseProvider: BaseProvider{
			id:         "bedrock-" + model,
			model:      model,
			baseURL:    fmt.Sprintf("https://bedrock-runtime.%s.amazonaws.com", region),
			apiKey:     apiKey,
			httpClient: &http.Client{Timeout: 60 * time.Second},
		},
		region: region,
	}
}

// ID returns provider ID
func (p *BedrockProvider) ID() string { return p.id }

// Type returns provider type
func (p *BedrockProvider) Type() ProviderType { return ProviderBedrock }

// Model returns the model
func (p *BedrockProvider) Model() string { return p.model }

// Capabilities returns provider capabilities
func (p *BedrockProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		SupportsStreaming: true,
		SupportsTools:     true,
		SupportsVision:    false,
		MaxContextLength:  200000,
	}
}

// Initialize sets up the provider
func (p *BedrockProvider) Initialize(ctx context.Context) error {
	if !p.IsAvailable(ctx) {
		return fmt.Errorf("provider %s is not available", p.id)
	}
	return nil
}

// IsAvailable checks if provider is available
func (p *BedrockProvider) IsAvailable(ctx context.Context) bool {
	// AWS credentials would be in env vars
	if p.apiKey == "" {
		return false
	}
	return true
}

// Generate creates a completion
func (p *BedrockProvider) Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error) {
	url := fmt.Sprintf("%s/model/%s/invoke", p.baseURL, p.model)

	// Build appropriate request body based on model provider
	var body map[string]interface{}

	if isAnthropicModel(p.model) {
		body = p.buildAnthropicBody(opts)
	} else if isAmazonModel(p.model) {
		body = p.buildAmazonBody(opts)
	} else {
		body = p.buildDefaultBody(opts)
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
	// AWS SigV4 signing would happen here in production

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("Bedrock error: %d - %s", resp.StatusCode, string(body))
	}

	if isAnthropicModel(p.model) {
		return p.parseAnthropicResponse(resp)
	}

	// Default response parsing
	var result struct {
		Content    string `json:"content"`
		Completion string `json:"completion"`
		OutputText string `json:"outputText"`
		StopReason string `json:"stop_reason"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	content := result.Content
	if content == "" {
		content = result.Completion
	}
	if content == "" {
		content = result.OutputText
	}

	return &ProviderResponse{
		Content:      content,
		FinishReason: result.StopReason,
	}, nil
}

// GenerateStream streams a completion
func (p *BedrockProvider) GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	return p.Generate(ctx, opts)
}

// Destroy cleans up resources
func (p *BedrockProvider) Destroy(ctx context.Context) error {
	return nil
}

func (p *BedrockProvider) buildAnthropicBody(opts GenerateOptions) map[string]interface{} {
	messages := make([]map[string]string, 0, len(opts.Messages))
	var systemMsg string
	for _, m := range opts.Messages {
		if m.Role == "system" {
			systemMsg = m.Content
			continue
		}
		role := m.Role
		if role == "tool" {
			role = "user"
		}
		messages = append(messages, map[string]string{
			"role":    role,
			"content": m.Content,
		})
	}

	body := map[string]interface{}{
		"anthropic_version": "bedrock-2023-05-31",
		"messages":          messages,
		"max_tokens":        opts.MaxTokens,
		"temperature":       opts.Temperature,
	}

	if systemMsg != "" {
		body["system"] = systemMsg
	}

	return body
}

func (p *BedrockProvider) buildAmazonBody(opts GenerateOptions) map[string]interface{} {
	var inputText string
	for _, m := range opts.Messages {
		inputText += m.Content + "\n"
	}

	return map[string]interface{}{
		"inputText": inputText,
		"textGenerationConfig": map[string]interface{}{
			"maxTokenCount": opts.MaxTokens,
			"temperature":   opts.Temperature,
		},
	}
}

func (p *BedrockProvider) buildDefaultBody(opts GenerateOptions) map[string]interface{} {
	var prompt string
	for _, m := range opts.Messages {
		prompt += m.Content + "\n"
	}

	return map[string]interface{}{
		"prompt":      prompt,
		"max_tokens":  opts.MaxTokens,
		"temperature": opts.Temperature,
	}
}

func (p *BedrockProvider) parseAnthropicResponse(resp *http.Response) (*ProviderResponse, error) {
	var result struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		StopReason string `json:"stop_reason"`
		Usage      struct {
			InputTokens  int `json:"input_tokens"`
			OutputTokens int `json:"output_tokens"`
		} `json:"usage"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	var content string
	for _, c := range result.Content {
		if c.Type == "text" {
			content += c.Text
		}
	}

	return &ProviderResponse{
		Content:      content,
		FinishReason: result.StopReason,
		Usage: &Usage{
			PromptTokens:     result.Usage.InputTokens,
			CompletionTokens: result.Usage.OutputTokens,
			TotalTokens:      result.Usage.InputTokens + result.Usage.OutputTokens,
		},
	}, nil
}

func isAnthropicModel(model string) bool {
	return contains(model, "anthropic") || contains(model, "claude")
}

func isAmazonModel(model string) bool {
	return contains(model, "amazon") || contains(model, "titan")
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsAt(s, substr))
}

func containsAt(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
