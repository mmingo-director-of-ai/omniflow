// OmniFlow host adapter for the canonical Atlas SDK. Models remain in the
// Swift host. MCP uses explicitly configured local or HTTPS connections.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

const protocolVersion = 4
const maxFrameBytes = 256 * 1024
const maxSteps = 128
const runTimeout = time.Hour

var sdkVersion = "development"
var sdkRevision = "development"

type toolDefinition struct {
	Name            string `json:"name"`
	Description     string `json:"description"`
	InputSchemaJSON string `json:"inputSchemaJSON"`
}

type toolCall struct {
	Name          string `json:"name"`
	ArgumentsJSON string `json:"argumentsJSON"`
}

type frame struct {
	Memory            *memoryView        `json:"memory,omitempty"`
	Analysis          *analysisRequest   `json:"analysis,omitempty"`
	AnalysisResult    *analysisReply     `json:"analysisResult,omitempty"`
	AnalysisError     string             `json:"analysisError,omitempty"`
	Question          string             `json:"question,omitempty"`
	DiscoveryQuery    string             `json:"discoveryQuery,omitempty"`
	MCPTool           *mcpSelectedTool   `json:"mcpTool,omitempty"`
	MCPDiscovery      []mcpDiscovery     `json:"mcpDiscovery,omitempty"`
	PayloadReady      bool               `json:"payloadReady"`
	PreviousError     string             `json:"previousError,omitempty"`
	PreviousOperation string             `json:"previousOperation,omitempty"`
	Broker            *mcpBrokerEndpoint `json:"broker,omitempty"`
	Mode              string             `json:"mode,omitempty"`
	Servers           []mcpServerConfig  `json:"servers,omitempty"`
	StoreDirectory    string             `json:"storeDirectory,omitempty"`
	Persistent        bool               `json:"persistent,omitempty"`
	Resume            bool               `json:"resume,omitempty"`
	ArchivedMessages  int                `json:"archivedMessages,omitempty"`
	Type              string             `json:"type"`
	Version           int                `json:"version,omitempty"`
	RequestID         string             `json:"requestID,omitempty"`
	ID                string             `json:"id,omitempty"`
	SDKVersion        string             `json:"sdkVersion,omitempty"`
	Revision          string             `json:"revision,omitempty"`
	Prompt            string             `json:"prompt,omitempty"`
	Content           string             `json:"content,omitempty"`
	Error             string             `json:"error,omitempty"`
	Tool              string             `json:"tool,omitempty"`
	ArgumentsJSON     string             `json:"argumentsJSON,omitempty"`
	Tools             []toolDefinition   `json:"tools,omitempty"`
	ToolCalls         []toolCall         `json:"toolCalls,omitempty"`
	Messages          []agent.Message    `json:"messages,omitempty"`
	FinalStep         bool               `json:"finalStep,omitempty"`
	Step              int                `json:"step,omitempty"`
	Steps             int                `json:"steps,omitempty"`
	ToolCount         int                `json:"toolCount"`
	StopReason        string             `json:"stopReason,omitempty"`
	Success           bool               `json:"success,omitempty"`
}

type input struct {
	frame frame
	err   error
}
type bridge struct {
	previousOperation string
	previousError     string
	in                <-chan input
	out               *json.Encoder
	requestID         string
	sequence          int
	step              int
	tools             map[string]agent.Tool
	cancel            context.CancelFunc
	store             *payloadStore
	mcp               *mcpHost
	mcpDiscovery      []mcpDiscovery
	discoveryDone     bool
	discoveryQuery    string
	memory            *taskMemory
}

func readFrames(ctx context.Context, reader io.Reader) <-chan input {
	ch := make(chan input)
	go func() {
		defer close(ch)
		emit := func(item input) bool {
			select {
			case ch <- item:
				return true
			case <-ctx.Done():
				return false
			}
		}
		scanner := bufio.NewScanner(reader)
		scanner.Buffer(make([]byte, 4096), maxFrameBytes)
		for scanner.Scan() {
			var f frame
			if err := json.Unmarshal(scanner.Bytes(), &f); err != nil {
				emit(input{err: errors.New("invalid_frame")})
				return
			}
			if !emit(input{frame: f}) {
				return
			}
		}
		if scanner.Err() != nil {
			emit(input{err: errors.New("frame_limit")})
		}
	}()
	return ch
}

func (b *bridge) receive(ctx context.Context) (frame, error) {
	select {
	case <-ctx.Done():
		return frame{}, ctx.Err()
	case item, ok := <-b.in:
		if !ok {
			return frame{}, io.EOF
		}
		if item.err != nil {
			return frame{}, item.err
		}
		return item.frame, nil
	}
}

func (b *bridge) send(f frame) error {
	f.Version = protocolVersion
	f.RequestID = b.requestID
	return b.out.Encode(f)
}

func (b *bridge) exchange(ctx context.Context, f frame) (result frame, failure error) {
	// A broken private transport is terminal; never retry it as a tool failure.
	defer func() {
		if failure != nil {
			b.cancel()
		}
	}()
	b.sequence++
	f.ID = fmt.Sprintf("%d", b.sequence)
	if err := b.send(f); err != nil {
		return frame{}, err
	}
	r, err := b.receive(ctx)
	if err != nil {
		return frame{}, err
	}
	if r.Type == "cancel" && r.RequestID == b.requestID {
		return frame{}, context.Canceled
	}
	if r.Version != protocolVersion || r.Type != "reply" || r.RequestID != b.requestID || r.ID != f.ID {
		return frame{}, errors.New("reply_mismatch")
	}
	if r.Error != "" {
		return frame{}, errors.New("host_failed")
	}
	return r, nil
}

func (b *bridge) Generate(ctx context.Context, messages []agent.Message, _ []agent.ToolSchema) (*agent.GenerateResult, error) {
	b.step++
	// Continue only local analysis of the already-fetched payload. Never replay
	// the MCP operation when a model window or an analysis batch ends.
	if job := b.memory.jobs[b.memory.active]; job != nil && !job.Complete && b.previousError == "" && b.step < maxSteps {
		return &agent.GenerateResult{ToolCalls: []agent.ToolCallData{{Name: "memory", ID: fmt.Sprintf("call_%d", b.step),
			Arguments: map[string]interface{}{"operation": "analyze", "id": job.ID, "query": job.Goal}}}}, nil
	}
	if !b.discoveryDone {
		b.discoveryDone = true
		b.mcpDiscovery = b.mcp.discover(ctx, b.discoveryQuery)
	}
	// Tool results have durable run-scoped payload IDs. Carry a recent window;
	// older evidence remains accessible through payload.list/search/read.
	archived := 0
	if len(messages) > 13 {
		archived = len(messages) - 13
		messages = append([]agent.Message{messages[0]}, messages[len(messages)-12:]...)
	}
	payloadReady := false
	for _, entry := range b.store.entries {
		if entry.Text && entry.Chunks > 0 && entry.Kind != "schema" {
			payloadReady = true
			break
		}
	}
	memory := b.memory.view(b.store.question)
	r, err := b.exchange(ctx, frame{Type: "model", Memory: &memory, Messages: messages, ArchivedMessages: archived, Step: b.step, FinalStep: b.step == maxSteps, PayloadReady: payloadReady, PreviousOperation: b.previousOperation, PreviousError: b.previousError, MCPTool: b.mcp.selectedTool(), MCPDiscovery: b.mcpDiscovery})
	if err != nil {
		return nil, err
	}
	if len(r.Content) > 16000 || len(r.ToolCalls) > 1 {
		return nil, errors.New("response_limit")
	}
	result := &agent.GenerateResult{Content: r.Content}
	for _, call := range r.ToolCalls {
		if b.step == maxSteps {
			return nil, errors.New("step_limit")
		}
		if _, exists := b.tools[call.Name]; !exists {
			return nil, errors.New("tool_denied")
		}
		var args map[string]interface{}
		if err := json.Unmarshal([]byte(call.ArgumentsJSON), &args); err != nil || args == nil {
			return nil, errors.New("invalid_arguments")
		}
		result.ToolCalls = append(result.ToolCalls, agent.ToolCallData{
			Name: call.Name, Arguments: args, ID: fmt.Sprintf("call_%d", b.step),
		})
	}
	if len(result.ToolCalls) == 0 && result.Content == "" {
		return nil, errors.New("empty_answer")
	}
	return result, nil
}

type hostTool struct {
	definition toolDefinition
	schema     map[string]interface{}
	bridge     *bridge
}

func (t hostTool) Name() string                        { return t.definition.Name }
func (t hostTool) Description() string                 { return t.definition.Description }
func (t hostTool) InputSchema() map[string]interface{} { return t.schema }
func (t hostTool) Execute(ctx context.Context, args map[string]interface{}) (interface{}, error) {
	encoded, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	r, err := t.bridge.exchange(ctx, frame{Type: "tool", Tool: t.Name(), ArgumentsJSON: string(encoded)})
	if err != nil {
		return nil, err
	}
	t.bridge.previousOperation = t.Name()
	t.bridge.previousError = ""
	source := "native:" + t.Name()
	if operation, ok := args["operation"].(string); ok {
		source += ":" + utf8Prefix(operation, 32)
	}
	if path, ok := args["path"].(string); ok {
		source += ":" + utf8Prefix(path, 512)
	}
	entry, err := t.bridge.store.put(source, []byte(r.Content), true)
	if err != nil {
		return nil, err
	}
	return t.bridge.store.preview(entry), nil
}

type localTool struct {
	bridge      *bridge
	name        string
	description string
	execute     func(context.Context, map[string]interface{}) (interface{}, error)
}

func (t localTool) Name() string        { return t.name }
func (t localTool) Description() string { return t.description }
func (t localTool) Execute(ctx context.Context, args map[string]interface{}) (interface{}, error) {
	if operation, ok := args["operation"].(string); ok && len(operation) < 32 {
		t.bridge.previousOperation = t.name + "." + operation
	}
	t.bridge.previousError = ""
	value, err := t.execute(ctx, args)
	if err != nil {
		t.bridge.previousError = safeToolError(err)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		// Errors are fixed host codes, never server-supplied text or credentials.
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "error": safeToolError(err), "complete": false}), nil
	}
	if t.name == "mcp" {
		if encoded, ok := value.(string); ok {
			var status struct {
				IsError bool `json:"isError"`
			}
			if json.Unmarshal([]byte(encoded), &status) == nil && status.IsError {
				t.bridge.previousError = "mcp_tool_reported_error"
			}
		}
	}
	return value, nil
}
func safeToolError(err error) string {
	text := err.Error()
	for _, character := range text {
		if !(character == '_' || character >= 'a' && character <= 'z' || character >= '0' && character <= '9') {
			return "local_tool_failed"
		}
	}
	if len(text) > 100 {
		return "local_tool_failed"
	}
	return text
}

func serve(ctx context.Context, reader io.Reader, writer io.Writer) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	b := &bridge{in: readFrames(ctx, reader), out: json.NewEncoder(writer), tools: make(map[string]agent.Tool), cancel: cancel}
	if err := b.send(frame{Type: "ready", SDKVersion: sdkVersion, Revision: sdkRevision}); err != nil {
		return err
	}
	start, err := b.receive(ctx)
	if err != nil {
		return err
	}
	if start.Version != protocolVersion || start.Type != "start" || len(start.RequestID) < 1 || len(start.RequestID) > 64 ||
		len(start.Prompt) == 0 || len(start.Prompt) > 64000 || (start.Mode != "catalog" && (len(start.Tools) < 2 || len(start.Tools) > 3)) ||
		len(start.Question) > 8000 || len(start.DiscoveryQuery) > 8000 || (start.Persistent && (start.StoreDirectory == "" || start.Mode != "")) ||
		(start.Resume && (!start.Persistent || len(start.Servers) != 0 || start.Mode != "")) {
		return errors.New("invalid_start")
	}
	b.requestID = start.RequestID
	b.discoveryQuery = start.DiscoveryQuery
	if b.discoveryQuery == "" {
		b.discoveryQuery = start.Question
	}
	b.store, err = newPayloadStore(start.StoreDirectory)
	if err != nil {
		return err
	}
	b.store.persistent = start.Persistent
	defer b.store.close()
	if len(start.Question) > 8000 {
		return errors.New("question_limit")
	}
	b.store.question = start.Question
	if start.Persistent {
		if err := b.store.enablePersistence(start.Resume); err != nil {
			return err
		}
	}
	b.memory = newTaskMemory(b)
	if start.Resume {
		if err := b.memory.restore(); err != nil {
			return err
		}
	}
	b.mcp, err = newMCPHost(start.Servers, b.store)
	if err != nil {
		return err
	}
	defer b.mcp.close()
	b.mcp.broker = start.Broker
	for _, server := range start.Servers {
		if server.Enabled && server.Transport != "http" && start.Broker == nil {
			return errors.New("mcp_launcher_unavailable")
		}
	}
	if start.Mode == "catalog" {
		if len(start.Servers) != 1 {
			return errors.New("catalog_requires_one_server")
		}
		result, err := b.mcp.catalog(ctx, start.Servers[0].ID)
		if err != nil {
			return err
		}
		return b.send(frame{Type: "done", Content: result, Steps: 1, ToolCount: 0, StopReason: "stop"})
	}
	if start.Mode != "" {
		return errors.New("unknown_mode")
	}
	for _, definition := range start.Tools {
		if definition.Name != "getMacContext" && definition.Name != "inspectLocalFiles" && definition.Name != "recallSavedMemory" {
			return errors.New("tool_denied")
		}
		if _, duplicate := b.tools[definition.Name]; duplicate {
			return errors.New("duplicate_tool")
		}
		var schema map[string]interface{}
		if json.Unmarshal([]byte(definition.InputSchemaJSON), &schema) != nil || schema["type"] != "object" {
			return errors.New("invalid_schema")
		}
		b.tools[definition.Name] = hostTool{definition, schema, b}
	}
	b.tools["mcp"] = localTool{bridge: b, name: "mcp", description: "Discover approved MCP tools, inspect their schemas, call them, and read approved resources.", execute: b.mcp.execute}
	b.tools["payload"] = localTool{bridge: b, name: "payload", description: "Search or read run-scoped evidence outside the model context window.", execute: b.store.execute}
	b.tools["memory"] = localTool{bridge: b, name: "memory", description: "Preserve exact findings, retrieve earlier notes, and analyze large stored sources in successive bounded passes.", execute: b.memory.execute}
	deadline := runTimeout
	loop := agent.NewAgentLoop(b, b.tools, agent.AgentLoopConfig{
		MaxSteps: maxSteps, Timeout: &deadline, ParallelExecution: false, AutoRecovery: false,
		OnToolCall: func(execution agent.ToolExecution) {
			if err := b.store.persistIndex(); err != nil {
				b.cancel()
			}
			// Discovery receipts must not imply that a named MCP tool ran.
			invoked := execution.Name != "mcp" || execution.Arguments["operation"] == "call" || execution.Arguments["operation"] == "readResource"
			if invoked && execution.Name != "memory" && execution.Name != "payload" {
				if err := b.memory.receipt(execution.Name, execution.Arguments, execution.Success && b.previousError == ""); err != nil {
					b.cancel()
				}
			}
			// Counts and status only. Neither arguments nor results go to telemetry.
			_ = b.send(frame{Type: "event", Tool: execution.Name, Step: b.step, Success: execution.Success && b.previousError == ""})
		},
	})
	result, err := loop.Execute(ctx, start.Prompt, nil)
	if err != nil {
		return err
	}
	if result.FinishReason != agent.StopConditionStop {
		return errors.New("incomplete_run")
	}
	return b.send(frame{Type: "done", Content: result.Text, Steps: len(result.Steps), ToolCount: len(result.ToolCalls), StopReason: string(result.FinishReason)})
}

func main() {
	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if len(os.Args) == 2 && os.Args[1] == "--mcp-broker" {
		if serveMCPBroker(signalContext, os.Stdin) != nil {
			os.Exit(1)
		}
		return
	}
	ctx, cancel := context.WithTimeout(signalContext, runTimeout)
	defer cancel()
	if err := serve(ctx, os.Stdin, os.Stdout); err != nil {
		// Do not print errors that might embed a prompt, path, argument or tool result.
		code := "atlas_run_failed"
		switch err.Error() {
		case "mcp_authentication_required", "mcp_http_forbidden", "mcp_http_endpoint_unavailable", "mcp_http_redirect_refused", "mcp_http_timeout", "mcp_http_rate_limited", "mcp_http_connection_failed":
			code = err.Error()
		}
		_ = json.NewEncoder(os.Stdout).Encode(frame{Type: "error", Version: protocolVersion, Error: code})
		os.Exit(1)
	}
}
