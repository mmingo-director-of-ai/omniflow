# Atlas SDK for Go

> "Any LLM, Any Tool, Any Talent, Anywhere"

The official Go SDK for Atlas - a unified framework that enables any LLM to use tools, MCP servers, and talents with a consistent interface.

## Features

- **Multi-Provider Support**: Ollama, OpenAI, Anthropic, Azure, Bedrock, Gemini, and any OpenAI-compatible API
- **Tool Registry**: Register custom tools with JSON Schema
- **MCP Integration**: Connect to any Model Context Protocol server
- **Talents**: Anthropic-style skill packages for reusable capabilities
- **Streaming**: Real-time response streaming
- **Fallback**: Automatic provider fallback on failure
- **Platform Foundations**: Scoped intelligence, conversation checkpoints, and policy routing
- **Error Handling**: Structured error types for debugging

The foundation contracts share portable wire fixtures with the TypeScript SDK.
Conversation branch heads use SQLite compare-and-swap version tokens, including
concurrent-writer conflict detection and losing-checkpoint cleanup.
See [Platform foundations](../../docs/platform-foundations.md) for ownership and
integration guidance.

## Support and compatibility policy

The Go SDK uses Go 1.24 language compatibility and is tested with `go vet`, the
race detector, the shared platform-foundation wire fixture, and the repository
coverage floor. TypeScript is the leading implementation for browser adapters,
MCP Apps, and optional npm packages. Go maintains behavioral parity for core
provider routing, conversations, intelligence portability, tools, talents,
subagents, stores, and MCP tool discovery/execution; features outside that list
must be documented as intentionally TypeScript-only rather than silently
approximated.

MCP advertises the stable `2025-11-25` revision. Discovered tools are registered
with their JSON schema and retain their originating server at execution time.
Set `ToolPrefix` on `MCPServerConfig` when servers expose colliding names;
duplicate exposed names fail initialization rather than overwriting a tool.

Go changes ship with the coordinated Atlas tag. Consumers should pin a module
tag and upgrade deliberately; incompatible public API changes require the next
major Atlas tag.

## Installation

```bash
go get gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go
```

## Quick Start

```go
package main

import (
    "context"
    "fmt"
    "log"

    "gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/atlas"
)

func main() {
    // Create Atlas instance with Ollama provider
    cfg := &atlas.Config{
        Provider:    "ollama",
        Model:       "qwen2.5-coder:32b",
        BaseURL:     "http://localhost:11434/v1",
        MaxSteps:    10,
        Temperature: 0.7,
    }

    a := atlas.New(cfg)

    // Initialize Atlas
    ctx := context.Background()
    if err := a.Initialize(ctx); err != nil {
        log.Fatalf("Failed to initialize Atlas: %v", err)
    }
    defer a.Destroy(ctx)

    // Execute a prompt
    result, err := a.Execute(ctx, atlas.ExecuteOptions{
        Messages: []atlas.Message{
            {Role: "user", Content: "Hello! What can you help me with?"},
        },
    })
    if err != nil {
        log.Fatalf("Execution failed: %v", err)
    }

    fmt.Println("Response:", result.Text)
}
```

## Provider Configuration

### Ollama (Default)

```go
cfg := &atlas.Config{
    Provider: "ollama",
    Model:    "qwen2.5-coder:32b",
    BaseURL:  "http://localhost:11434/v1",
}
```

### OpenAI

```go
cfg := &atlas.Config{
    Provider: "openai",
    Model:    "gpt-4",
    APIKey:   os.Getenv("OPENAI_API_KEY"),
}
```

### Anthropic

```go
cfg := &atlas.Config{
    Provider: "anthropic",
    Model:    "claude-3-5-sonnet-20241022",
    APIKey:   os.Getenv("ANTHROPIC_API_KEY"),
}
```

### Azure OpenAI

```go
cfg := &atlas.Config{
    Provider: "azure",
    Model:    "gpt-4",
    BaseURL:  "https://your-resource.openai.azure.com",
    APIKey:   os.Getenv("AZURE_OPENAI_KEY"),
}
```

### Google Gemini

```go
cfg := &atlas.Config{
    Provider: "google",
    Model:    "gemini-pro",
    APIKey:   os.Getenv("GOOGLE_API_KEY"),
}
```

### AWS Bedrock

```go
cfg := &atlas.Config{
    Provider: "bedrock",
    Model:    "anthropic.claude-3-sonnet-20240229-v1:0",
    Region:   "us-east-1",
    // AWS credentials from env: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
}
```

## Registering Tools

```go
// Define a custom tool
calculatorTool := tools.Tool{
    Name:        "calculator",
    Description: "Perform arithmetic calculations",
    InputSchema: map[string]interface{}{
        "type": "object",
        "properties": map[string]interface{}{
            "operation": map[string]interface{}{
                "type": "string",
                "enum": []string{"add", "subtract", "multiply", "divide"},
            },
            "a": map[string]interface{}{"type": "number"},
            "b": map[string]interface{}{"type": "number"},
        },
        "required": []string{"operation", "a", "b"},
    },
    Handler: func(ctx context.Context, args map[string]interface{}, toolCtx tools.Context) (interface{}, error) {
        op := args["operation"].(string)
        a := args["a"].(float64)
        b := args["b"].(float64)

        switch op {
        case "add":
            return a + b, nil
        case "subtract":
            return a - b, nil
        case "multiply":
            return a * b, nil
        case "divide":
            if b == 0 {
                return nil, fmt.Errorf("division by zero")
            }
            return a / b, nil
        }
        return nil, fmt.Errorf("unknown operation: %s", op)
    },
}

// Register the tool
a.RegisterTool(calculatorTool)

// Execute with tools enabled
result, err := a.Execute(ctx, atlas.ExecuteOptions{
    Messages: []atlas.Message{
        {Role: "user", Content: "What is 25 * 4?"},
    },
    Tools: []string{"calculator"}, // Optional: restrict to specific tools
})
```

## Streaming Responses

```go
result, err := a.ExecuteStream(ctx, atlas.ExecuteOptions{
    Messages: []atlas.Message{
        {Role: "user", Content: "Tell me a story"},
    },
}, func(chunk atlas.StreamChunk) {
    switch chunk.Type {
    case "content":
        fmt.Print(chunk.Content)
    case "tool":
        fmt.Printf("\n[Tool: %s]\n", chunk.ToolCall.Name)
    case "finish":
        fmt.Printf("\n[Finished: %s]\n", chunk.FinishReason)
    }
})
```

## MCP Integration

```go
// Connect to an MCP server
cfg.MCPServers = []atlas.MCPServerConfig{
    {
        Name: "filesystem",
        ToolPrefix: "filesystem__", // recommended when multiple servers are configured
        Transport: atlas.MCPTransportConfig{
            Type:    "stdio",
            Command: "npx",
            Args:    []string{"-y", "@modelcontextprotocol/server-filesystem", "/tmp"},
        },
    },
}

a := atlas.New(cfg)
a.Initialize(ctx)
```

## Loading Talents

```go
// Load talents from directory
talent, err := a.LoadTalent("./talents/investigate-threat")
if err != nil {
    log.Fatal(err)
}

// Enable the talent
a.EnableTalent(talent.Metadata.Name)

// Execute with the talent's context
result, err := a.Execute(ctx, atlas.ExecuteOptions{
    Messages: []atlas.Message{
        {Role: "user", Content: "Analyze this suspicious activity"},
    },
})
```

## Architecture

```
sdk/go/
├── pkg/
│   ├── atlas/          # Core Atlas orchestration
│   ├── providers/      # LLM provider implementations
│   ├── tools/          # Tool registry
│   ├── talents/        # Talent loader
│   └── mcp/            # MCP client
└── examples/           # Example applications
```

## Documentation

See the [main Atlas documentation](../../docs/) for more details:

- [SDK Documentation](../../docs/sdk.md)
- [Provider Configuration](../../docs/sdk.md#configuration)
- [Talent Authoring](../../docs/talents.md)
- [MCP Integration](../../docs/mcp.md)

## License

MIT
