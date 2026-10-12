// Basic example of using Atlas SDK for Go
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

	// Simple execution without tools
	result, err := a.Execute(ctx, atlas.ExecuteOptions{
		Messages: []atlas.Message{
			{Role: "user", Content: "Hello! What can you help me with?"},
		},
	})
	if err != nil {
		log.Fatalf("Execution failed: %v", err)
	}

	fmt.Println("Response:", result.Text)
	fmt.Println("Finish reason:", result.FinishReason)

	// Check state
	state := a.GetState()
	fmt.Printf("State: %+v\n", state)
}
