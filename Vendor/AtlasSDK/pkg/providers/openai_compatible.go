package providers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// OpenAICompatibleProvider implements any OpenAI-compatible API (Ollama, LocalAI, etc.)
type OpenAICompatibleProvider struct {
	BaseProvider
	providerType string
}

// NewOpenAICompatibleProvider creates an OpenAI-compatible provider
func NewOpenAICompatibleProvider(model, apiKey, baseURL, providerType string) *OpenAICompatibleProvider {
	if baseURL == "" {
		if providerType == "ollama" {
			baseURL = "http://localhost:11434/v1"
		} else {
			baseURL = "http://localhost:8080/v1"
		}
	}
	return &OpenAICompatibleProvider{
		BaseProvider: BaseProvider{
			id:         providerType + "-" + model,
			model:      model,
			baseURL:    baseURL,
			apiKey:     apiKey,
			httpClient: &http.Client{Timeout: 60 * time.Second},
		},
		providerType: providerType,
	}
}

// ID returns provider ID
func (p *OpenAICompatibleProvider) ID() string { return p.id }

// Type returns provider type
func (p *OpenAICompatibleProvider) Type() ProviderType {
	if p.providerType == "ollama" {
		return ProviderOllama
	}
	return ProviderOpenAICompat
}

// Model returns the model
func (p *OpenAICompatibleProvider) Model() string { return p.model }

// Capabilities returns provider capabilities
func (p *OpenAICompatibleProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		SupportsStreaming: true,
		SupportsTools:     p.providerType == "ollama", // Ollama supports tools
		SupportsVision:    false,
		MaxContextLength:  32768, // Typical for local models
	}
}

// Initialize sets up the provider
func (p *OpenAICompatibleProvider) Initialize(ctx context.Context) error {
	if !p.IsAvailable(ctx) {
		return fmt.Errorf("provider %s is not available", p.id)
	}
	return nil
}

// IsAvailable checks if provider is available
func (p *OpenAICompatibleProvider) IsAvailable(ctx context.Context) bool {
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

// ListModels lists available models from the provider
func (p *OpenAICompatibleProvider) ListModels() ([]string, error) {
	url := p.baseURL + "/models"
	req, err := http.NewRequest("GET", url, nil)
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
		return nil, fmt.Errorf("API error: %d - %s", resp.StatusCode, string(body))
	}

	var result struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	models := make([]string, 0)
	for _, m := range result.Data {
		if m.ID != "" {
			models = append(models, m.ID)
		}
	}
	// Ollama format
	for _, m := range result.Models {
		if m.Name != "" {
			models = append(models, m.Name)
		}
	}

	return models, nil
}

// Generate creates a completion
func (p *OpenAICompatibleProvider) Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error) {
	url := p.baseURL + "/chat/completions"

	body := map[string]interface{}{
		"model":       p.model,
		"messages":    opts.Messages,
		"temperature": opts.Temperature,
		"max_tokens":  opts.MaxTokens,
		"stop":        opts.Stop,
		"stream":      false,
	}

	if len(opts.Tools) > 0 && p.providerType == "ollama" {
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
		return nil, fmt.Errorf("API error: %d - %s", resp.StatusCode, string(body))
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content      string     `json:"content"`
				ToolCalls    []ToolCall `json:"tool_calls"`
				FinishReason string     `json:"finish_reason"`
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

	return &ProviderResponse{
		Content:      choice.Message.Content,
		ToolCalls:    choice.Message.ToolCalls,
		FinishReason: choice.FinishReason,
		Usage: &Usage{
			PromptTokens:     result.Usage.PromptTokens,
			CompletionTokens: result.Usage.CompletionTokens,
			TotalTokens:      result.Usage.TotalTokens,
		},
	}, nil
}

// GenerateStream streams a completion
func (p *OpenAICompatibleProvider) GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	url := p.baseURL + "/chat/completions"

	body := map[string]interface{}{
		"model":       p.model,
		"messages":    opts.Messages,
		"temperature": opts.Temperature,
		"max_tokens":  opts.MaxTokens,
		"stop":        opts.Stop,
		"stream":      true,
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
		return nil, fmt.Errorf("API error: %d - %s", resp.StatusCode, string(body))
	}

	// Read the SSE stream line-by-line. OpenAI-compatible servers frame events as
	// `data: {json}\n\n` with a `data: [DONE]` sentinel, so a raw json.Decoder
	// cannot be used: it errors on the `data: ` prefix and, because the failing
	// bytes are never consumed, the loop never advances -> CPU busy-loop until the
	// context/timeout fires. Mirror the Ollama provider's line-buffered handler.
	var fullContent strings.Builder
	var finishReason string

	scanner := bufio.NewScanner(resp.Body)
	// Increase the buffer for larger SSE events
	buf := make([]byte, 0, 4096)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		// SSE data lines are prefixed with `data:`; skip any other field lines
		// (event:, id:, retry:, comments) that some gateways emit.
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))

		// Stream-completion sentinel
		if payload == "[DONE]" {
			break
		}

		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
				FinishReason string `json:"finish_reason"`
			} `json:"choices"`
		}

		if err := json.Unmarshal([]byte(payload), &chunk); err != nil {
			// Skip malformed events
			continue
		}

		if len(chunk.Choices) > 0 {
			content := chunk.Choices[0].Delta.Content
			if content != "" {
				fullContent.WriteString(content)
				onChunk(StreamChunk{Type: "content", Content: content})
			}
			if chunk.Choices[0].FinishReason != "" {
				finishReason = chunk.Choices[0].FinishReason
				onChunk(StreamChunk{Type: "finish", FinishReason: finishReason})
				break
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("stream scanner error: %w", err)
	}

	if finishReason == "" {
		finishReason = "stop"
	}

	return &ProviderResponse{
		Content:      fullContent.String(),
		FinishReason: finishReason,
	}, nil
}

// Destroy cleans up resources
func (p *OpenAICompatibleProvider) Destroy(ctx context.Context) error {
	return nil
}
