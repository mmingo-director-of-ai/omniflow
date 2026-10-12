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

// OllamaProvider implements native Ollama API using /api/chat endpoint
type OllamaProvider struct {
	BaseProvider
}

// NewOllamaProvider creates a native Ollama provider
func NewOllamaProvider(model, apiKey, baseURL string) *OllamaProvider {
	if baseURL == "" {
		baseURL = "http://localhost:11434"
	}
	baseURL = strings.TrimRight(baseURL, "/")

	return &OllamaProvider{
		BaseProvider: BaseProvider{
			id:         "ollama-" + model,
			model:      model,
			baseURL:    baseURL,
			apiKey:     apiKey,
			httpClient: &http.Client{Timeout: 5 * time.Minute},
		},
	}
}

// ID returns provider ID
func (p *OllamaProvider) ID() string { return p.id }

// Type returns provider type
func (p *OllamaProvider) Type() ProviderType { return ProviderOllama }

// Model returns the model
func (p *OllamaProvider) Model() string { return p.model }

// Capabilities returns provider capabilities
func (p *OllamaProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{
		SupportsStreaming: true,
		SupportsTools:     true,
		SupportsVision:    false,
		MaxContextLength:  128000,
	}
}

// Initialize sets up the provider
func (p *OllamaProvider) Initialize(ctx context.Context) error {
	if !p.IsAvailable(ctx) {
		return fmt.Errorf("provider %s is not available", p.id)
	}
	return nil
}

// IsAvailable checks if provider is available
func (p *OllamaProvider) IsAvailable(ctx context.Context) bool {
	req, err := http.NewRequestWithContext(ctx, "GET", p.baseURL+"/api/tags", nil)
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

// ListModels lists available models from Ollama
func (p *OllamaProvider) ListModels() ([]string, error) {
	req, err := http.NewRequest("GET", p.baseURL+"/api/tags", nil)
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
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	models := make([]string, len(result.Models))
	for i, m := range result.Models {
		models[i] = m.Name
	}
	return models, nil
}

// ollamaTool is the wire format Ollama expects for tool definitions
type ollamaTool struct {
	Type     string         `json:"type"`
	Function ollamaFunction `json:"function"`
}

type ollamaFunction struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	Parameters  map[string]interface{} `json:"parameters"`
}

// toOllamaTools converts internal Tool definitions to the Ollama wire format
func toOllamaTools(tools []Tool) []ollamaTool {
	out := make([]ollamaTool, len(tools))
	for i, t := range tools {
		out[i] = ollamaTool{
			Type: "function",
			Function: ollamaFunction{
				Name:        t.Name,
				Description: t.Description,
				Parameters:  t.InputSchema,
			},
		}
	}
	return out
}

// ollamaRequest is the request body for /api/chat
type ollamaRequest struct {
	Model    string       `json:"model"`
	Messages []Message    `json:"messages"`
	Tools    []ollamaTool `json:"tools,omitempty"`
	Stream   bool         `json:"stream"`
	Options  *ollamaOpts  `json:"options,omitempty"`
}

type ollamaOpts struct {
	Temperature float64 `json:"temperature,omitempty"`
	NumPredict  int     `json:"num_predict,omitempty"`
}

// ollamaResponse is the NDJSON response from /api/chat
type ollamaResponse struct {
	Message struct {
		Content   string `json:"content"`
		Role      string `json:"role"`
		Thinking  string `json:"thinking,omitempty"`
		ToolCalls []struct {
			ID       string `json:"id"`
			Function struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			} `json:"function"`
		} `json:"tool_calls,omitempty"`
	} `json:"message"`
	Done       bool   `json:"done"`
	DoneReason string `json:"done_reason,omitempty"`
}

// Generate creates a completion (non-streaming)
func (p *OllamaProvider) Generate(ctx context.Context, opts GenerateOptions) (*ProviderResponse, error) {
	return p.GenerateStream(ctx, opts, func(StreamChunk) {})
}

// GenerateStream streams a completion using native Ollama /api/chat endpoint
func (p *OllamaProvider) GenerateStream(ctx context.Context, opts GenerateOptions, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	url := p.baseURL + "/api/chat"

	reqBody := ollamaRequest{
		Model:    p.model,
		Messages: opts.Messages,
		Stream:   true,
	}

	if len(opts.Tools) > 0 {
		reqBody.Tools = toOllamaTools(opts.Tools)
	}

	if opts.Temperature > 0 || opts.MaxTokens > 0 {
		reqBody.Options = &ollamaOpts{
			Temperature: opts.Temperature,
			NumPredict:  opts.MaxTokens,
		}
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if p.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+p.apiKey)
	}

	resp, err := p.httpClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return &ProviderResponse{FinishReason: "interrupted"}, nil
		}
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API error: %s - %s", resp.Status, string(respBody))
	}

	return p.handleNDJSONStream(resp.Body, onChunk)
}

func (p *OllamaProvider) handleNDJSONStream(body io.Reader, onChunk func(StreamChunk)) (*ProviderResponse, error) {
	scanner := bufio.NewScanner(body)
	// Increase buffer for larger responses
	buf := make([]byte, 0, 4096)
	scanner.Buffer(buf, 1024*1024)

	var content strings.Builder
	var toolCalls []ToolCall
	var finishReason string

	// Track whether we're inside a <think> block in the content field
	// Some models (DeepSeek-R1, QwQ) emit thinking as <think>...</think> in the content field
	inThinkTag := false

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var resp ollamaResponse
		if err := json.Unmarshal([]byte(line), &resp); err != nil {
			// Skip malformed lines
			continue
		}

		// Handle native thinking field - don't accumulate into content
		if resp.Message.Thinking != "" {
			onChunk(StreamChunk{Type: "thinking", Content: resp.Message.Thinking})
		}

		// Handle content field - parse out <think> tags that some models embed
		if resp.Message.Content != "" {
			remaining := resp.Message.Content
			for remaining != "" {
				if inThinkTag {
					// Look for </think> close tag
					if idx := strings.Index(remaining, "</think>"); idx >= 0 {
						// Everything before </think> is thinking content
						thinkPart := remaining[:idx]
						if thinkPart != "" {
							onChunk(StreamChunk{Type: "thinking", Content: thinkPart})
						}
						remaining = remaining[idx+len("</think>"):]
						inThinkTag = false
					} else {
						// Still inside think block - all of remaining is thinking
						if onChunk != nil {
							onChunk(StreamChunk{Type: "thinking", Content: remaining})
						}
						remaining = ""
					}
				} else {
					// Look for <think> open tag
					if idx := strings.Index(remaining, "<think>"); idx >= 0 {
						// Everything before <think> is real content
						contentPart := remaining[:idx]
						if contentPart != "" {
							content.WriteString(contentPart)
							if onChunk != nil {
								onChunk(StreamChunk{Type: "content", Content: contentPart})
							}
						}
						remaining = remaining[idx+len("<think>"):]
						inThinkTag = true
					} else {
						// No think tags - all real content
						content.WriteString(remaining)
						if onChunk != nil {
							onChunk(StreamChunk{Type: "content", Content: remaining})
						}
						remaining = ""
					}
				}
			}
		}

		// Accumulate tool calls
		for _, tc := range resp.Message.ToolCalls {
			var args map[string]interface{}
			if err := json.Unmarshal(tc.Function.Arguments, &args); err != nil {
				args = make(map[string]interface{})
			}
			toolCalls = append(toolCalls, ToolCall{
				ID:        tc.ID,
				Name:      tc.Function.Name,
				Arguments: args,
			})
			onChunk(StreamChunk{
				Type: "tool_call",
				ToolCall: &ToolCall{
					ID:        tc.ID,
					Name:      tc.Function.Name,
					Arguments: args,
				},
			})
		}

		if resp.Done {
			finishReason = resp.DoneReason
			if finishReason == "" {
				finishReason = "stop"
			}
			break
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scanner error: %w", err)
	}

	if finishReason == "" {
		finishReason = "stop"
	}
	if len(toolCalls) > 0 {
		finishReason = "tool_calls"
	}

	onChunk(StreamChunk{Type: "finish", FinishReason: finishReason})

	return &ProviderResponse{
		Content:      content.String(),
		ToolCalls:    toolCalls,
		FinishReason: finishReason,
	}, nil
}

// Destroy cleans up resources
func (p *OllamaProvider) Destroy(ctx context.Context) error {
	return nil
}
